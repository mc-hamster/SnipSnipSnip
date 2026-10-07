import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "check-repository-hygiene.py"


class RepositoryHygieneTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.environment = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        self.git("init", "--quiet")

    def git(self, *arguments):
        return subprocess.run(["git", "-C", str(self.root), *arguments],
                              env=self.environment, capture_output=True, check=True)

    def add(self, name, data=b"fixture\n", executable=False):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        if executable:
            path.chmod(0o755)
        self.git("add", "--force", "--", name)
        return path

    def check(self, *arguments):
        return subprocess.run([sys.executable, str(SCRIPT), "--repository", str(self.root), *arguments],
                              env=self.environment, capture_output=True, text=True)

    def test_ignores_untracked_local_build_products(self):
        self.add(".gitignore", b"node_modules/\nbuild/\n")
        self.add("App.swift", b"struct App {}\n")
        path = self.root / "node_modules/example/index.js"
        path.parent.mkdir(parents=True)
        path.write_text("generated")
        self.assertEqual(self.check().returncode, 0)

    def test_rejects_force_added_repository_ignored_files(self):
        self.add(".gitignore", b"*.log\n/assets/App Store/**/*-AppStore.zip\n")
        self.add("assets/App Store/Next version/Submission-AppStore.zip")
        self.add("capture.log")
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Submission-AppStore.zip", result.stderr)
        self.assertIn("ignored by .gitignore", result.stderr)
        self.assertIn("capture.log", result.stderr)

    def test_generated_directories_are_rejected_even_without_ignore_rules(self):
        for name in ("node_modules/example/index.js", "build/output.txt", ".venv/bin/tool",
                     "DerivedData/cache", "Project.xcodeproj/xcuserdata/user/state",
                     "Results.xcresult/Info.plist", "App.app/Contents/Info.plist"):
            self.add(name)
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.count("generated dependency/build directory"), 7)

    def test_nested_ignore_and_explicit_negation_rules(self):
        self.add("assets/.gitignore", b"*.zip\n!fixture.zip\n")
        self.add("assets/fixture.zip")
        self.assertEqual(self.check().returncode, 0)
        self.add("assets/package.zip")
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("assets/.gitignore:1", result.stderr)
        self.assertNotIn("fixture.zip", result.stderr)

    def test_personal_ignore_rules_do_not_reject_intentional_assets(self):
        (self.root / ".git/info/exclude").write_text("*.png\n")
        self.add("AppIcon.png")
        self.assertEqual(self.check().returncode, 0)

    def test_compiled_executables_and_libraries_are_rejected(self):
        self.add("bin/film-control", b"\xcf\xfa\xed\xfecompiled", executable=True)
        self.add("bin/elf-tool", b"\x7fELFcompiled")
        self.add("lib/helper.dylib")
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.count("compiled executable"), 2)
        self.assertIn("compiled build product", result.stderr)

    def test_source_scripts_original_artwork_and_icon_variants_are_allowed(self):
        self.add("bin/tool", b"#!/bin/sh\nexit 0\n", executable=True)
        for name in ("artwork.key", "source.afphoto", "preview.mp4", "fixture.zip", "package-lock.json",
                     "icon_16x16@2x.png", "icon_32x32.png", "Chapter 2.md"):
            self.add(name)
        self.assertEqual(self.check().returncode, 0)

    def test_identical_copy_names_are_rejected_without_deduplicating_resources(self):
        self.add("assets/caption.png")
        for name in ("assets/caption 2.png", "assets/caption 10.png", "assets/caption copy.png",
                     "assets/caption copy 3.png"):
            self.add(name)
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.count("identical copy"), 4)

    def test_duplicate_archives_with_multiple_extensions_are_rejected(self):
        self.add("archive.tar.gz")
        self.add("archive 2.tar.gz")
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("identical copy", result.stderr)

    def test_different_contents_with_numbered_names_are_allowed(self):
        self.add("Chapter.md", b"first\n")
        self.add("Chapter 2.md", b"second\n")
        self.assertEqual(self.check().returncode, 0)

    def test_working_tree_checks_accept_pending_cleanup_deletions(self):
        path = self.add("node_modules/example/index.js")
        path.unlink()
        self.assertEqual(self.check().returncode, 0)
        result = self.check("--staged")
        self.assertEqual(result.returncode, 1)
        self.assertIn("node_modules", result.stderr)

    def test_staged_check_uses_index_contents_for_duplicate_detection(self):
        self.add("asset.png")
        copy = self.add("asset 2.png")
        copy.write_bytes(b"different work in progress")
        self.assertEqual(self.check().returncode, 0)
        self.assertEqual(self.check("--staged").returncode, 1)

    def test_staged_check_reads_binary_headers_from_the_index(self):
        binary = self.add("bin/tool", b"\xfe\xed\xfa\xcfcompiled", executable=True)
        binary.write_bytes(b"#!/bin/sh\nexit 0\n")
        self.assertEqual(self.check().returncode, 0)
        result = self.check("--staged")
        self.assertEqual(result.returncode, 1)
        self.assertIn("compiled executable", result.stderr)

    def test_unstaged_ignore_removal_cannot_hide_a_staged_artifact(self):
        ignore = self.add(".gitignore", b"*.log\n")
        self.add("debug.log")
        ignore.write_bytes(b"# unstaged policy change\n")
        self.assertEqual(self.check().returncode, 0)
        result = self.check("--staged")
        self.assertEqual(result.returncode, 1)
        self.assertIn("ignored by .gitignore", result.stderr)

    def test_unstaged_ignore_addition_does_not_change_the_staged_verdict(self):
        ignore = self.add(".gitignore", b"# indexed policy\n")
        self.add("fixture.log")
        ignore.write_bytes(b"*.log\n")
        self.assertEqual(self.check().returncode, 1)
        self.assertEqual(self.check("--staged").returncode, 0)

    def test_null_delimited_git_paths_handle_newlines_and_spaces(self):
        self.add(".gitignore", b"*.log\n")
        self.add("logs/space and\nnewline.log")
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("space and\\nnewline.log", result.stderr)

    def test_missing_git_repository_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(SCRIPT), "--repository", directory],
                                    env=self.environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("not a git repository", result.stderr)


if __name__ == "__main__":
    unittest.main()
