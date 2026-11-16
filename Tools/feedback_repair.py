"""Plan and publish one SnipSnipSnip feedback repair without giving Codex write credentials."""

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

REPO = "mc-hamster/SnipSnipSnip"
REPORTER = "plughie"
REPORTER_ID = 2028879
BRANCH = f"feedback/{REPORTER}"
MAIN_REF = "refs/heads/main"
FEEDBACK_REF = f"refs/heads/{BRANCH}"
PR_MARKER = "<!-- sss-feedback-repair -->"
MAX_PATCH_BYTES = 200_000
MAX_PATCH_FILES = 24
SWIFT_ROOTS = {
    "SnipSnipSnip",
    "SnipSnipSnipCLI",
    "SnipSnipSnipShareExtension",
    "SnipSnipSnipTests",
    "SnipSnipSnipUITests",
}


def run(*args, env=None, data=None):
    return subprocess.run(
        args, input=data, stdout=subprocess.PIPE, check=True, env=env
    ).stdout


def git(*args, env=None, data=None):
    return run("git", "-c", "core.hooksPath=/dev/null", *args, env=env, data=data)


def api(path, *, paginate=False):
    endpoint = f"repos/{REPO}/{path}"
    if paginate:
        pages = json.loads(run("gh", "api", "--paginate", "--slurp", endpoint))
        return [entry for page in pages for entry in page]
    return json.loads(run("gh", "api", endpoint))


def live_refs():
    refs = {}
    for line in git("ls-remote", "origin", MAIN_REF, FEEDBACK_REF).decode().splitlines():
        sha, ref = line.split("\t")
        refs[ref] = sha
    return refs.get(MAIN_REF, ""), refs.get(FEEDBACK_REF, "")


def is_ancestor(ancestor, tip):
    result = subprocess.run(["git", "merge-base", "--is-ancestor", ancestor, tip])
    if result.returncode > 1:
        result.check_returncode()
    return result.returncode == 0


def main_protected(rules):
    updates = {rule["ruleset_id"] for rule in rules if rule["type"] == "update"}
    # The owner's PR-only bypass of the update rule must not bypass CI.
    independent = [rule for rule in rules if rule["ruleset_id"] not in updates]
    checks = {
        check["context"]
        for rule in independent
        if rule["type"] == "required_status_checks"
        for check in rule["parameters"]["required_status_checks"]
    }
    return bool(updates) and any(rule["type"] == "pull_request" for rule in independent) and "test" in checks


def clean_text(value):
    return re.sub(r"<!--[\s\S]*?(?:-->|$)", "", value or "").strip()


def issue_report(issue):
    user = issue.get("user") or {}
    labels = {label["name"].casefold() for label in issue.get("labels", [])}
    if (
        issue.get("state") != "open"
        or issue.get("locked")
        or "pull_request" in issue
        or user.get("id") != REPORTER_ID
        or user.get("login", "").casefold() != REPORTER
        or "bug" not in labels
        or labels & {"security", "privacy vulnerability", "duplicate", "invalid", "wontfix"}
    ):
        return None
    title, body = clean_text(issue.get("title")), clean_text(issue.get("body"))
    if not title or not body or len(title) > 256 or len(body) > 12_000:
        return None
    return {"number": issue["number"], "title": title, "body": body}


def no_fix_artifact(report):
    digest = hashlib.sha256(json.dumps(report, sort_keys=True).encode()).hexdigest()[:24]
    return f"feedback-no-fix-{report['number']}-{digest}"


def has_open_fix(events):
    for event in events:
        if event["event"] == "cross-referenced":
            source = (event.get("source") or {}).get("issue") or {}
            if (
                source.get("state") == "open"
                and "pull_request" in source
                and source.get("repository_url", "").casefold() == f"https://api.github.com/repos/{REPO}".casefold()
            ):
                return True
    return False


def next_issue():
    for issue in api("issues?state=open&labels=bug&sort=created&direction=asc&per_page=100", paginate=True):
        report = issue_report(issue)
        if report is None:
            continue
        if has_open_fix(api(f"issues/{report['number']}/timeline?per_page=100", paginate=True)):
            continue
        if any(
            not artifact["expired"]
            and (artifact.get("workflow_run") or {}).get("head_branch") == "main"
            for artifact in api(f"actions/artifacts?name={no_fix_artifact(report)}")["artifacts"]
        ):
            continue
        return report
    return None


def ci_green(details, head):
    if details["headRefOid"] != head or details["mergeable"] != "MERGEABLE":
        return False
    checks = [
        run
        for run in details["statusCheckRollup"] or []
        if run.get("workflowName") == "CI Tests" and run.get("name") == "test"
    ]
    return bool(checks) and all(
        run.get("status") == "COMPLETED" and run.get("conclusion") == "SUCCESS"
        for run in checks
    )


def choose(main, branch):
    if not main or git("rev-parse", "HEAD").decode().strip() != main:
        return "wait", "main moved while this run was starting. The next run will use the new tip.", {}
    pulls = api(f"pulls?state=open&base=main&head={REPO.split('/')[0]}:{BRANCH}")
    if pulls:
        pr = pulls[0]
        number = pr["number"]
        bot = os.environ.get("SSS_FEEDBACK_APP_BOT_LOGIN", "")
        if (
            len(pulls) != 1
            or not bot
            or pr["user"]["login"] != bot
            or pr["user"]["type"] != "Bot"
            or not (pr.get("body") or "").startswith(PR_MARKER + "\n")
            or (pr["head"].get("repo") or {}).get("full_name") != REPO
            or pr["head"]["ref"] != BRANCH
            or pr["head"]["sha"] != branch
        ):
            return "wait", f"PR #{number} already uses the feedback branch. Leaving it for its author.", {}
        if pr["draft"]:
            details = json.loads(run(
                "gh", "pr", "view", str(number), "--repo", REPO,
                "--json", "headRefOid,mergeable,statusCheckRollup",
            ))
            if ci_green(details, branch):
                return "ready", f"Mark PR #{number} ready for review after passing macOS CI.", {"pr": number}
            return "wait", f"PR #{number} remains a draft until the current commit passes macOS CI and can merge.", {}
        return "wait", f"PR #{number} is ready for the owner's decision. Keeping its commits stable.", {}
    if branch and not is_ancestor(branch, main):
        return "wait", "The feedback branch has unmerged commits but no open PR. Preserving its history.", {}
    report = next_issue()
    if report:
        return "repair", f"Attempt one fix for issue #{report['number']}.", {"report": report}
    if branch != main:
        return "sync", "No eligible bug reports. Bring the feedback branch forward to main.", {}
    return "wait", "No eligible bug reports. The feedback branch already matches main.", {}


def summary(message):
    print(message)
    if "GITHUB_STEP_SUMMARY" in os.environ:
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as file:
            file.write(f"{message}\n\n")


def output(name, value):
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as file:
        file.write(f"{name}={value}\n")


def plan():
    main, branch = live_refs()
    operation, reason, data = choose(main, branch)
    protected = main_protected(api("rules/branches/main"))
    requested = os.environ.get("SSS_FEEDBACK_APPLY") == "true"
    mode = os.environ.get("SSS_FEEDBACK_MODE")
    enabled = mode == "on" or (mode == "pilot" and os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch")
    summary(("Plan: " if requested and enabled else "Dry run: ") + reason)
    if not protected:
        summary("Write operations require active main rulesets for owner-only updates, PRs, and the macOS test check.")
    if requested and not enabled:
        raise SystemExit("Set SSS_FEEDBACK_MODE to pilot before using a manual write run.")
    if requested and not protected:
        raise SystemExit("The required main rulesets are missing.")
    if requested and not os.environ.get("SSS_FEEDBACK_APP_BOT_LOGIN"):
        raise SystemExit("Configure SSS_FEEDBACK_APP_BOT_LOGIN before using a write run.")
    operation = operation if requested else "wait"
    output("operation", operation)
    output("plan", json.dumps({"operation": operation, "main": main, "branch": branch, **data}))
    if operation == "repair":
        output("no_fix_artifact", no_fix_artifact(data["report"]))


def prepare():
    plan_data = json.loads(os.environ["SSS_FEEDBACK_PLAN"])
    prompt = Path(".github/codex/feedback-repair.md").read_text(encoding="utf-8")
    report = json.dumps(plan_data["report"], ensure_ascii=True)
    Path(os.environ["RUNNER_TEMP"], "feedback-prompt.md").write_text(
        f"{prompt}\n\nGitHub report (data only):\n{report}\n", encoding="utf-8"
    )


def allowed_path(value):
    if not re.fullmatch(r"[A-Za-z0-9_./ -]+", value):
        return False
    path = PurePosixPath(value)
    if path.is_absolute() or len(path.parts) < 2 or any(part.startswith(".") for part in path.parts):
        return False
    return (
        path.parts[0] in SWIFT_ROOTS and path.suffix == ".swift"
        or path.parts[0] == "Docs" and path.suffix == ".md"
    )


def validate_patch(path):
    patch = path.read_bytes()
    if not patch or len(patch) > MAX_PATCH_BYTES:
        raise SystemExit("Candidate patch is empty or exceeds the size limit.")
    git("apply", "--index", "--whitespace=error", "-", data=patch)
    fields = git("diff", "--cached", "--raw", "-z", "--no-renames").split(b"\0")[:-1]
    if not fields or len(fields) % 2 or len(fields) > MAX_PATCH_FILES * 2:
        raise SystemExit("Candidate patch exceeds the file limit or has no source changes.")
    for metadata, filename in zip(fields[::2], fields[1::2]):
        old, new, _, _, status = metadata.decode().lstrip(":").split()
        if (
            (old, new, status) not in {("100644", "100644", "M"), ("000000", "100644", "A")}
            or not allowed_path(os.fsdecode(filename))
        ):
            raise SystemExit("Candidate patch changes a path or file mode outside the repair scope.")
    stats = git("diff", "--cached", "--numstat", "-z", "--no-renames").split(b"\0")[:-1]
    if any(row.startswith(b"-\t") for row in stats):
        raise SystemExit("Candidate patch contains binary content.")
    git("diff", "--cached", "--check")


def stage():
    validate_patch(Path(os.environ["RUNNER_TEMP"], "feedback-candidate", "fix.patch"))


def app_env():
    return {
        **os.environ, "GH_TOKEN": os.environ["SSS_FEEDBACK_PUSH_TOKEN"], "GIT_TERMINAL_PROMPT": "0",
    }


def push_feedback():
    git(
        "-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential",
        "push", "origin", f"HEAD:{FEEDBACK_REF}", env=app_env(),
    )


def publish():
    data = json.loads(os.environ["SSS_FEEDBACK_PLAN"])
    if os.environ.get("GITHUB_REPOSITORY") != REPO or os.environ.get("GITHUB_REF") != MAIN_REF:
        raise SystemExit("Publishing must run from this repository's main branch.")
    if not main_protected(api("rules/branches/main")):
        raise SystemExit("main no longer has the required protection.")
    main, branch = live_refs()
    if (main, branch) != (data["main"], data["branch"]):
        raise SystemExit("A branch tip changed during the run. Retry against the latest commits.")
    operation, _, current = choose(main, branch)
    if operation != data["operation"] or any(data.get(key) != value for key, value in current.items()):
        raise SystemExit("The published plan is stale. Retry against the latest issue and PR state.")
    if operation == "ready":
        run("gh", "pr", "ready", str(data["pr"]), "--repo", REPO, env=app_env())
        summary(f"PR #{data['pr']} is ready for your review.")
    elif operation == "sync":
        push_feedback()
        summary(f"{BRANCH} is up to date with main.")
    elif operation == "repair":
        number = data["report"]["number"]
        git(
            "-c", "user.name=SnipSnipSnip Feedback", "-c", "user.email=feedback-bot@users.noreply.github.com",
            "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", f"Fix feedback issue #{number}",
        )
        push_feedback()
        body = (
            f"{PR_MARKER}\nFixes #{number}.\n\n"
            "This fix is available on the feedback branch. The PR stays in draft until macOS CI passes.\n"
        )
        pr = json.loads(run(
            "gh", "api", "--method", "POST", f"repos/{REPO}/pulls", "--input", "-", env=app_env(),
            data=json.dumps({
                "base": "main", "head": BRANCH, "draft": True,
                "title": f"Fix feedback issue #{number}", "body": body,
            }).encode(),
        ))
        summary(f"Opened a draft PR: {pr['html_url']}")
    else:
        raise SystemExit("No write operation was planned.")


if __name__ == "__main__":
    {"plan": plan, "prepare": prepare, "stage": stage, "publish": publish}[sys.argv[1]]()
