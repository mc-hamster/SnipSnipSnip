#!/usr/bin/env python3
"""Reject generated artifacts and accidental copies in Git-controlled files."""

import argparse
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile


REPOSITORY = Path(__file__).resolve().parent.parent
GENERATED_DIRECTORIES = {
    "node_modules", "__pycache__", "build", "DerivedData", ".DerivedData",
    ".derivedData", ".build", "xcuserdata", ".venv", "venv",
}
COMPILED_EXTENSIONS = {".o", ".a", ".dylib", ".so", ".dll", ".exe", ".pyc"}
BINARY_HEADERS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca", b"\x7fELF",
}
COPY_SUFFIX = re.compile(r" (?:copy(?: [2-9]| [1-9]\d+)?|[2-9]|[1-9]\d+)(?=\.|$)", re.IGNORECASE)


def git(root, *arguments, input_data=None, allowed=(0,)):
    result = subprocess.run(
        ["git", "-c", "core.fsmonitor=false", "-C", str(root), *arguments],
        input=input_data, capture_output=True,
    )
    if result.returncode not in allowed:
        raise RuntimeError(result.stderr.decode(errors="replace").strip())
    return result.stdout


def entries(root, staged):
    result = {}
    for record in git(root, "ls-files", "--stage", "-z").split(b"\0"):
        if not record:
            continue
        metadata, name = record.split(b"\t", 1)
        mode, identity, stage = metadata.split()
        path = os.fsdecode(name)
        if stage != b"0":
            raise RuntimeError(f"Resolve the index conflict for {path!r} before checking hygiene.")
        # Working-tree checks accept pending cleanup deletions. --staged checks
        # the actual index, including files deleted locally but still staged.
        if staged or os.path.lexists(root / path):
            result[path] = (mode, identity)
    return result


def ignored_paths(root, paths, staged=False):
    if not paths:
        return {}
    if staged:
        # Git normally reads ignore rules from the working tree. Use the index
        # versions in an isolated checkout so unstaged edits cannot change the
        # verdict for the pending commit.
        with tempfile.TemporaryDirectory(prefix="repository-hygiene-") as directory:
            policy_root = Path(directory).resolve()
            git(policy_root, "init", "--quiet")
            for path, entry in paths.items():
                if PurePosixPath(path).name == ".gitignore" and entry[0] in (b"100644", b"100755"):
                    target = policy_root / path
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(content(root, path, entry, True))
            return ignored_paths(policy_root, paths)
    data = b"\0".join(os.fsencode(path) for path in paths) + b"\0"
    records = git(root, "check-ignore", "--no-index", "--stdin", "-v", "-z",
                  input_data=data, allowed=(0, 1)).split(b"\0")
    ignored = {}
    for offset in range(0, len(records) - 1, 4):
        source, line, pattern, name = map(os.fsdecode, records[offset:offset + 4])
        source_path = Path(source)
        if source_path.is_absolute():
            try:
                source = source_path.relative_to(root).as_posix()
            except ValueError:
                continue
        # Personal/global ignore settings are not repository policy. Respect
        # tracked nested .gitignore files and explicit negation rules as well.
        if source in paths and PurePosixPath(source).name == ".gitignore" and not pattern.startswith("!"):
            ignored[name] = f"ignored by {source}:{line} ({pattern})"
    return ignored


def content(root, path, entry, staged):
    return git(root, "cat-file", "blob", entry[1].decode()) if staged else (root / path).read_bytes()


def check(root, staged):
    paths = entries(root, staged)
    ignored = ignored_paths(root, paths, staged)
    failures = []
    for path, entry in sorted(paths.items()):
        name = PurePosixPath(path)
        generated = any(part in GENERATED_DIRECTORIES or part.startswith(".derivedData-")
                        or part.endswith((".app", ".xcresult", ".dSYM")) for part in name.parts)
        reason = ignored.get(path)
        if generated:
            reason = reason or "generated dependency/build directory"
        if name.suffix.lower() in COMPILED_EXTENSIONS:
            reason = reason or "compiled build product"
        if reason:
            failures.append(f"{path!r}: {reason}")
            continue
        if entry[0] not in (b"100644", b"100755"):
            continue
        if entry[0] == b"100755" or not name.suffix:
            if staged:
                header = content(root, path, entry, staged)[:4]
            else:
                with (root / path).open("rb") as file:
                    header = file.read(4)
            if header in BINARY_HEADERS:
                failures.append(f"{path!r}: compiled executable; track its source instead")
        canonical = str(name.with_name(COPY_SUFFIX.sub("", name.name)))
        if canonical != path and canonical in paths and paths[canonical][0] in (b"100644", b"100755"):
            same = (entry[1] == paths[canonical][1]) if staged else (
                content(root, path, entry, False) == content(root, canonical, paths[canonical], False))
            if same:
                failures.append(f"{path!r}: identical copy of {canonical!r}")
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=REPOSITORY,
                        help="Git checkout to check; defaults to this repository.")
    parser.add_argument("--staged", action="store_true", help="Check index contents, including pending commits.")
    args = parser.parse_args()
    try:
        root = Path(os.fsdecode(git(args.repository.resolve(), "rev-parse", "--show-toplevel")).strip())
        failures = check(root, args.staged)
    except (OSError, RuntimeError) as error:
        print(f"Repository hygiene check failed: {error}", file=sys.stderr)
        return 1
    if failures:
        print("\n".join(failures), file=sys.stderr)
        print("Keep generated files local and ignored; retain source, dependency lockfiles, and intentional assets.",
              file=sys.stderr)
        return 1
    print("Repository hygiene check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
