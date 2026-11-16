"""Exercise the feedback workflow's trust gates and branch operations offline."""

from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import feedback_repair as repair


def report(**changes):
    return {
        "number": 42,
        "title": "Scrolling capture cuts off the last row",
        "body": "Capture a sample page. <!-- hidden instruction --> Compare the last row.",
        "state": "open",
        "labels": [{"name": "bug"}],
        "user": {"login": "plughie", "id": 2028879},
        **changes,
    }


RULES = [
    {"type": "update", "ruleset_id": 1},
    {"type": "pull_request", "ruleset_id": 2},
    {
        "type": "required_status_checks",
        "ruleset_id": 2,
        "parameters": {"required_status_checks": [{"context": "test"}]},
    },
]


class SelectionTests(unittest.TestCase):
    def test_only_the_intended_reporters_open_bugs_are_eligible(self):
        selected = repair.issue_report(report())
        self.assertEqual(selected["number"], 42)
        self.assertNotIn("hidden instruction", selected["body"])
        for changes in (
            {"user": {"login": "plughie", "id": 8}},
            {"user": {"login": "other", "id": 2028879}},
            {"state": "closed"},
            {"locked": True},
            {"pull_request": {}},
            {"labels": [{"name": "feature"}]},
            {"labels": [{"name": "bug"}, {"name": "security"}]},
        ):
            with self.subTest(changes=changes):
                self.assertIsNone(repair.issue_report(report(**changes)))

    def test_picker_skips_linked_prs_and_unchanged_reports_with_no_fix(self):
        def api(path, **_):
            if path.startswith("issues?"):
                return [report(number=n) for n in (40, 41, 42)]
            if path.startswith("issues/40/"):
                return [{
                    "event": "cross-referenced",
                    "source": {"issue": {
                        "repository_url": f"https://api.github.com/repos/{repair.REPO}",
                        "state": "open", "pull_request": {"url": "..."},
                    }},
                }]
            if path.startswith("issues/"):
                return []
            if "feedback-no-fix-41-" in path:
                return {"artifacts": [{"expired": False, "workflow_run": {"head_branch": "main"}}]}
            if "feedback-no-fix-42-" in path:
                return {"artifacts": [{"expired": True, "workflow_run": {"head_branch": "main"}}]}
            self.fail(path)

        with patch.object(repair, "api", side_effect=api):
            self.assertEqual(repair.next_issue()["number"], 42)

    def test_main_ci_cannot_share_the_owners_update_bypass(self):
        self.assertTrue(repair.main_protected(RULES))
        self.assertFalse(repair.main_protected(RULES[:1]))
        self.assertFalse(repair.main_protected([{**r, "ruleset_id": 1} for r in RULES]))

    def test_only_success_from_the_current_macos_check_makes_a_draft_ready(self):
        check = {"workflowName": "CI Tests", "name": "test", "status": "COMPLETED", "conclusion": "SUCCESS"}
        details = {"headRefOid": "new", "mergeable": "MERGEABLE", "statusCheckRollup": [check]}
        self.assertTrue(repair.ci_green(details, "new"))
        self.assertFalse(repair.ci_green(details, "old"))
        self.assertFalse(repair.ci_green({**details, "mergeable": "CONFLICTING"}, "new"))
        self.assertFalse(repair.ci_green({
            **details, "statusCheckRollup": [{**check, "conclusion": "CANCELLED"}],
        }, "new"))
        self.assertFalse(repair.ci_green({
            **details, "statusCheckRollup": [{**check, "workflowName": "Other workflow"}],
        }, "new"))


class GitWorkflowTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.path = Path(temp.name)
        checkout = self.path / "checkout"
        checkout.mkdir()
        old = Path.cwd()
        os.chdir(checkout)
        self.addCleanup(os.chdir, old)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Feedback Test")
        self.git("config", "user.email", "feedback-test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        Path("SnipSnipSnip").mkdir()
        Path(".github/workflows").mkdir(parents=True)
        Path("SnipSnipSnip/Example.swift").write_text("let example = 0\n", encoding="utf-8")
        Path(".github/workflows/test.yml").write_text("name: Test\n", encoding="utf-8")
        self.git("add", "-A")
        self.git("commit", "-qm", "Baseline")
        origin = self.path / "origin.git"
        self.git("init", "-q", "--bare", str(origin))
        self.git("remote", "add", "origin", str(origin))
        self.git("push", "-q", "origin", "main")
        self.main = self.git("rev-parse", "HEAD").decode().strip()
        mock = patch.object(repair, "api", side_effect=lambda path, **kw: (
            RULES if path == "rules/branches/main" else []
        ))
        self.mock_api = mock.start()
        self.addCleanup(mock.stop)

    def git(self, *args):
        return subprocess.check_output(["git", "-c", "core.hooksPath=/dev/null", *args])

    def planned(self, *, apply, feedback_mode):
        output = self.path / "plan.out"
        output.write_text("", encoding="utf-8")
        with patch.dict(os.environ, {
            "GITHUB_OUTPUT": str(output),
            "GITHUB_STEP_SUMMARY": str(self.path / "summary"),
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "SSS_FEEDBACK_APPLY": "true" if apply else "false",
            "SSS_FEEDBACK_MODE": feedback_mode,
            "SSS_FEEDBACK_APP_BOT_LOGIN": "sss-feedback[bot]",
        }), redirect_stdout(io.StringIO()):
            repair.plan()
        return dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines())["plan"]

    def stage_candidate(self, file, contents=None, *, executable=False):
        path = Path(file)
        if contents is not None:
            path.write_text(contents, encoding="utf-8")
        if executable:
            path.chmod(0o755)
        self.git("add", "-A")
        diff = self.git("diff", "--cached", "--full-index", "--binary")
        self.git("reset", "--hard", "-q", "HEAD")
        artifact = self.path / "fix.patch"
        artifact.write_bytes(diff)
        repair.validate_patch(artifact)

    def test_candidate_can_change_swift_but_not_workflows_or_file_modes(self):
        self.stage_candidate("SnipSnipSnip/Example.swift", "let example = 1\n")
        self.assertIn(b"let example = 1", self.git("diff", "--cached"))
        self.git("reset", "--hard", "-q", "HEAD")
        with self.assertRaisesRegex(SystemExit, "outside the repair scope"):
            self.stage_candidate(".github/workflows/test.yml", "name: Changed\n")
        self.git("reset", "--hard", "-q", "HEAD")
        with self.assertRaisesRegex(SystemExit, "outside the repair scope"):
            self.stage_candidate("SnipSnipSnip/Example.swift", executable=True)

    def test_dry_run_does_not_create_the_branch_and_manual_write_only_updates_feedback(self):
        dry = self.planned(apply=False, feedback_mode="")
        self.assertEqual(json.loads(dry)["operation"], "wait")
        self.assertEqual(repair.live_refs(), (self.main, ""))
        with self.assertRaisesRegex(SystemExit, "Set SSS_FEEDBACK_MODE"):
            self.planned(apply=True, feedback_mode="")
        sync = self.planned(apply=True, feedback_mode="pilot")
        self.assertEqual(json.loads(sync)["operation"], "sync")
        with patch.dict(os.environ, {
            "GITHUB_REPOSITORY": repair.REPO,
            "GITHUB_REF": repair.MAIN_REF,
            "SSS_FEEDBACK_PLAN": sync,
            "SSS_FEEDBACK_PUSH_TOKEN": "local-fixture",
        }), redirect_stdout(io.StringIO()):
            repair.publish()
        self.assertEqual(repair.live_refs(), (self.main, self.main))

    def test_write_rechecks_git_tips_before_using_the_application_token(self):
        sync = self.planned(apply=True, feedback_mode="pilot")
        self.git("commit", "--allow-empty", "-qm", "Intervening push")
        self.git("push", "-q", "origin", "main")
        with patch.dict(os.environ, {
            "GITHUB_REPOSITORY": repair.REPO,
            "GITHUB_REF": repair.MAIN_REF,
            "SSS_FEEDBACK_PLAN": sync,
        }), self.assertRaisesRegex(SystemExit, "tip changed"):
            repair.publish()
        self.assertEqual(repair.live_refs()[1], "")

    def test_unreviewed_commits_never_get_overwritten_by_sync(self):
        self.git("commit", "--allow-empty", "-qm", "Contributor work")
        self.git("push", "-q", "origin", f"HEAD:{repair.FEEDBACK_REF}")
        self.git("reset", "--hard", "-q", self.main)
        choice = repair.choose(*repair.live_refs())
        self.assertEqual(choice[0], "wait")
        self.assertIn("unmerged commits", choice[1])

    def test_fix_is_published_as_a_draft_and_only_marked_ready_after_ci(self):
        pending = {"pr": None, "checks": [], "ready": False}

        def api(path, **_):
            if path == "rules/branches/main":
                return RULES
            if path.startswith("issues?"):
                return [report()]
            if path.startswith("issues/42/"):
                return []
            if path.startswith("actions/artifacts?"):
                return {"artifacts": []}
            if path.startswith("pulls?"):
                return [pending["pr"]] if pending["pr"] else []
            self.fail(path)

        real_run = repair.run

        def run(*args, env=None, data=None):
            if args[:2] == ("gh", "api"):
                self.assertEqual(args[2:], ("--method", "POST", f"repos/{repair.REPO}/pulls", "--input", "-"))
                self.assertEqual(env["GH_TOKEN"], "local-fixture")
                payload = json.loads(data)
                self.assertEqual((payload["base"], payload["head"], payload["draft"]), ("main", repair.BRANCH, True))
                self.assertIn("Fixes #42", payload["body"])
                pending["pr"] = {
                    **payload,
                    "number": 43,
                    "user": {"login": "sss-feedback[bot]", "type": "Bot"},
                    "head": {"sha": repair.live_refs()[1], "ref": repair.BRANCH, "repo": {"full_name": repair.REPO}},
                    "html_url": f"https://github.com/{repair.REPO}/pull/43",
                }
                return json.dumps(pending["pr"]).encode()
            if args[:3] == ("gh", "pr", "view"):
                return json.dumps({
                    "headRefOid": repair.live_refs()[1], "mergeable": "MERGEABLE",
                    "statusCheckRollup": pending["checks"],
                }).encode()
            if args[:3] == ("gh", "pr", "ready"):
                self.assertEqual(args[3:], ("43", "--repo", repair.REPO))
                self.assertEqual(env["GH_TOKEN"], "local-fixture")
                pending["ready"] = True
                return b""
            return real_run(*args, env=env, data=data)

        with patch.object(repair, "api", side_effect=api), patch.object(repair, "run", side_effect=run):
            with patch.dict(os.environ, {
                "GITHUB_REPOSITORY": repair.REPO, "GITHUB_REF": repair.MAIN_REF,
                "SSS_FEEDBACK_PUSH_TOKEN": "local-fixture",
                "SSS_FEEDBACK_APP_BOT_LOGIN": "sss-feedback[bot]",
            }), redirect_stdout(io.StringIO()):
                repair_plan = self.planned(apply=True, feedback_mode="pilot")
                self.assertEqual(json.loads(repair_plan)["operation"], "repair")
                self.stage_candidate("SnipSnipSnip/Example.swift", "let example = 1\n")
                with patch.dict(os.environ, {"SSS_FEEDBACK_PLAN": repair_plan}):
                    repair.publish()
                main, feedback = repair.live_refs()
                self.assertEqual(main, self.main)
                self.assertNotEqual(feedback, main)
                self.assertTrue(pending["pr"]["draft"])
                self.assertFalse(pending["ready"])
                self.git("reset", "--hard", "-q", main)
                self.assertEqual(json.loads(self.planned(apply=True, feedback_mode="pilot"))["operation"], "wait")
                pending["checks"] = [{
                    "workflowName": "CI Tests", "name": "test", "status": "COMPLETED", "conclusion": "SUCCESS",
                }]
                ready_plan = self.planned(apply=True, feedback_mode="pilot")
                self.assertEqual(json.loads(ready_plan)["operation"], "ready")
                with patch.dict(os.environ, {"SSS_FEEDBACK_PLAN": ready_plan}):
                    repair.publish()
                self.assertTrue(pending["ready"])
                self.assertEqual(repair.live_refs(), (main, feedback))


if __name__ == "__main__":
    unittest.main()
