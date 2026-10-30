"""Behavioral routing controls and actual compiled workflow contracts."""
from fnmatch import fnmatchcase
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import sys

import yaml

ROOT = Path(__file__).parents[4]
SPEC = importlib.util.spec_from_file_location(
    "accessibility_handoff", Path(__file__).parents[1] / "scripts/accessibility_handoff.py")
HANDOFF = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HANDOFF)


def workflow(name):
    return yaml.safe_load((ROOT / f".github/workflows/{name}.lock.yml").read_text(encoding="utf-8"))


def step_named(job, name):
    return next(s for s in job["steps"] if s.get("name") == name)


def expand(text, attempt=1):
    return text.replace("${{ github.run_id }}", "12345").replace(
        "${{ github.run_attempt }}", str(attempt))


class RoutingTests(unittest.TestCase):
    def test_actual_cpp_state_change_is_a_valid_related_candidate_without_keyword_filter(self):
        path = "src/cascadia/TerminalApp/TerminalPage.cpp"
        self.assertEqual("Related", HANDOFF.triage(
            f"# Related\n\nHistory activation now silently clears a rejected action.\n\n- `{path}`\n", {path}))

    def test_none_and_uncertain_preserve_distinct_decisions(self):
        self.assertEqual("None", HANDOFF.triage("# None\n\nOnly a source comment was reworded.\n", set()))
        self.assertEqual("Uncertain", HANDOFF.triage(
            "# Uncertain\n\nCannot establish whether the new state is announced.\n", set()))

    def test_malformed_triage_cannot_silently_route_none(self):
        for text in ("", "# PASS\n\nNo issues", "# Related\n\nUI changed.",
                     "# None\n\n# Related\n", "# None\n\nReason\n\n- `absent.cpp`",
                     "# Related\n\nReason\n\n- `a.cpp`\n- `a.cpp`",
                     "# None\n\nReason\n\n- invalid bullet", "# None\n\n" + "x" * 17000):
            with self.subTest(text=text[:70]), self.assertRaises(ValueError):
                HANDOFF.triage(text, {"a.cpp"})

    def test_native_selection_is_a_supported_subset_not_uncertainty(self):
        self.assertEqual("agents", HANDOFF.native("# Native checks\n\nOnly agent settings changed.\n\n- agents\n"))
        self.assertEqual("fre,fre-settings", HANDOFF.native(
            "# Native checks\n\nWelcome navigation needs discovery.\n\n- fre-settings\n- fre\n"))
        self.assertEqual("", HANDOFF.native(
            "# Native checks\n\nThe smoke cannot cover unread horizontal tabs.\n\n- None\n"))
        for text in ("# Uncertain\n\nNeed Windows", "# Native checks\n\nReason\n- uncertain",
                     "# Native checks\n\nReason\n- agents\n- None",
                     "# Native checks\n\nReason\n- fre\n- fre",
                     "# Native checks\n\n- agents"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                HANDOFF.native(text)

    def test_triage_cli_uses_feature_merge_base_and_rejects_base_only_candidate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, text=True).strip()
            git("init", "-q", "--initial-branch=main")
            git("config", "user.name", "Test")
            git("config", "user.email", "test@example.invalid")
            (root / "page.cpp").write_text("void Activate() {}\n")
            git("add", ".")
            git("commit", "-qm", "base")
            git("checkout", "-qb", "feature")
            (root / "page.cpp").write_text("void Activate() { ClearError(); }\n")
            git("add", ".")
            git("commit", "-qm", "changed action without accessibility keywords")
            head = git("rev-parse", "HEAD")
            git("checkout", "-q", "main")
            (root / "base-only.cpp").write_text("// unrelated main update\n")
            git("add", ".")
            git("commit", "-qm", "base advances")
            base = git("rev-parse", "HEAD")
            for candidate, valid in (("page.cpp", True), ("base-only.cpp", False)):
                path = root / "triage.md"
                path.write_text(f"# Related\n\nChanged activation may affect feedback.\n\n- `{candidate}`\n")
                result = subprocess.run(
                    [sys.executable, str(Path(HANDOFF.__file__)), "triage", str(path),
                     "--base", base, "--head", head], cwd=root,
                    capture_output=True, text=True, timeout=30)
                self.assertEqual(valid, result.returncode == 0, result.stderr)


class CompiledContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.main = workflow("ghaw-pr-accessibility")
        cls.triage = workflow("ghaw-accessibility-triage")
        cls.summary = workflow("ghaw-accessibility-summary")

    def test_emitted_graph_schedules_uncertain_deep_but_only_selected_successful_native(self):
        jobs = self.main["jobs"]
        self.assertIn("triage-route", jobs["agent"]["needs"])
        condition = jobs["agent"]["if"]
        self.assertIn("== 'Related'", condition)
        self.assertIn("== 'Uncertain'", condition)
        self.assertNotIn("== 'None'", condition)
        self.assertEqual("agent", jobs["native-selection"]["needs"])
        self.assertIn("needs.agent.result == 'success'", jobs["native-runtime"]["if"])
        self.assertIn("outputs.surfaces != ''", jobs["native-runtime"]["if"])
        self.assertNotIn("Uncertain", jobs["native-runtime"]["if"])
        self.assertEqual("${{ needs.native-selection.outputs.surfaces }}",
                         jobs["native-runtime"]["with"]["surfaces"])
        self.assertIn("!cancelled()", jobs["final-summary"]["if"])
        self.assertIn("route != 'None'", jobs["final-summary"]["if"])

    def test_actual_outcomes_are_forwarded_to_summary_not_predicted_by_deep_agent(self):
        args = self.main["jobs"]["final-summary"]["with"]
        for name, value in {
            "triage-result": "needs.triage-route.result", "route": "needs.triage-route.outputs.route",
            "deep-result": "needs.agent.result", "native-result": "needs.native-runtime.result",
            "native-selection-result": "needs.native-selection.result",
            "publication-result": "needs.safe_outputs.result",
            "publication-status": "needs.safe_outputs.outputs.process_safe_outputs_status",
            "published-sha": "needs.safe_outputs.outputs.push_commit_sha",
        }.items():
            self.assertEqual("${{ " + value + " }}", args[name])
        outputs = self.main["jobs"]["safe_outputs"]["outputs"]
        for key in ("process_safe_outputs_status", "push_commit_sha"):
            self.assertIn(key, outputs)

    def test_none_displays_original_handoff_without_a_summary_model(self):
        route = next(
            s for s in self.main["jobs"]["triage-route"]["steps"] if s.get("id") == "route")
        self.assertIn('if [ "$route" = None ]', route["run"])
        self.assertIn('cat "Generated Files/$ACCESSIBILITY_RUN/triage.md"', route["run"])
        self.assertIn("not an accessibility PASS", route["run"])

    def test_internal_artifacts_are_namespaced_by_existing_ghaw_mechanism(self):
        for child in (self.triage, self.summary):
            steps = child["jobs"]["activation"]["steps"]
            prefix = next(s for s in steps if s.get("id") == "artifact-prefix")
            self.assertIn("compute_artifact_prefix.sh", prefix["run"])
            uploads = [s for s in child["jobs"]["agent"]["steps"]
                       if s.get("name") == "Upload agent artifacts"]
            self.assertEqual("${{ needs.activation.outputs.artifact_prefix }}agent",
                             uploads[0]["with"]["name"])
        # Triage has no inputs; summary always has named inputs, so its prefix
        # hash input is distinct on the same attempt. No replacement namespacer.
        triage_on = self.triage.get("on", self.triage.get(True))
        summary_on = self.summary.get("on", self.summary.get(True))
        self.assertEqual({"aw_context"}, set(triage_on["workflow_call"]["inputs"]))
        self.assertIn("deep-result", summary_on["workflow_call"]["inputs"])

    def test_reusable_permission_grants_cover_actual_child_jobs(self):
        for job_name, child in (("triage", self.triage), ("final-summary", self.summary)):
            caller = self.main["jobs"][job_name]["permissions"]
            for job in child["jobs"].values():
                for permission, level in job.get("permissions", {}).items():
                    if level != "none":
                        self.assertIn(permission, caller)
                        if level == "write":
                            self.assertEqual("write", caller[permission])
            self.assertEqual("read", child["jobs"]["agent"]["permissions"]["contents"])

    def test_reusable_safe_outputs_do_not_inject_issue_or_comment_publication(self):
        for child in (self.triage, self.summary):
            for job in child["jobs"].values():
                self.assertNotEqual("write", job.get("permissions", {}).get("issues"))
                for step in job.get("steps", []):
                    for key, value in step.get("env", {}).items():
                        if key in ("GH_AW_SAFE_OUTPUTS_CONFIG", "GH_AW_SAFE_OUTPUTS_HANDLER_CONFIG"):
                            config = json.loads(value)
                            self.assertNotIn("create_issue", config)
                            self.assertNotIn("add_comment", config)
                            self.assertNotIn("create_report_incomplete_issue", config)

    def test_retained_producers_download_on_partial_rerun_with_original_identity(self):
        producer = step_named(self.triage["jobs"]["agent"], "Preserve original triage even when incomplete")
        deep = step_named(self.main["jobs"]["agent"], "Upload raw source review even when incomplete")
        consumers = [
            next(s for s in self.main["jobs"]["triage-route"]["steps"] if "download-artifact@" in s.get("uses", "")),
            step_named(self.main["jobs"]["agent"], "Download original triage")]
        for consumer in consumers:
            self.assertEqual(expand(producer["with"]["name"], 1), expand(consumer["with"]["name"], 2))
            self.assertIn("${{ github.run_attempt }}", consumer["with"]["path"])
        selector = next(s for s in self.main["jobs"]["native-selection"]["steps"]
                        if "download-artifact@" in s.get("uses", ""))
        self.assertEqual(expand(deep["with"]["name"], 1), expand(selector["with"]["name"], 2))
        download = step_named(self.summary["jobs"]["agent"], "Download original review handoffs")
        for upload in (producer, deep):
            self.assertIn("always()", upload["if"])
            self.assertTrue(upload["with"]["overwrite"])
            self.assertTrue(fnmatchcase(expand(upload["with"]["name"], 1),
                                      expand(download["with"]["pattern"], 2)))
        self.assertFalse(fnmatchcase("accessibility-deep-999", expand(download["with"]["pattern"], 2)))

    def test_superseded_pr_cancellation_is_preserved(self):
        self.assertIs(True, self.main["concurrency"]["cancel-in-progress"])
        self.assertIn("github.event.pull_request.number", self.main["concurrency"]["group"])
        for stage in ("triage", "agent", "final-summary"):
            self.assertIn("needs.activation.outputs.daily_ai_credits_exceeded != 'true'",
                          self.main["jobs"][stage]["if"])

    def test_raw_display_step_executes_on_failure_and_preserves_agent_markdown(self):
        step = step_named(self.main["jobs"]["agent"], "Display raw review even when validation fails")
        self.assertEqual("always()", step["if"])
        bash = shutil.which("bash")
        if os.name == "nt":
            bash = str(Path(shutil.which("git")).parents[1] / "bin/bash.exe")
        for present in (False, True):
            with self.subTest(present=present), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                output = root / "Generated Files/accessibility-12345-2"
                output.mkdir(parents=True)
                raw = "## Outcome\nPartial source lead; not validated.\n"
                if present:
                    (output / "deep-summary.md").write_text(raw)
                summary = root / "step-summary.md"
                result = subprocess.run(
                    [bash, "--noprofile", "--norc"], cwd=root, input=step["run"], text=True,
                    capture_output=True, timeout=30,
                    env={**os.environ, "ACCESSIBILITY_RUN": "accessibility-12345-2",
                         "GITHUB_RUN_ID": "12345", "GITHUB_RUN_ATTEMPT": "2",
                         "PRODUCER_HEAD": "a" * 40, "PRODUCER_WORKFLOW": "b" * 40,
                         "VALIDATION_OUTCOME": "failure", "GITHUB_STEP_SUMMARY": summary.as_posix()})
                self.assertEqual(0, result.returncode, result.stderr)
                display = summary.read_text()
                self.assertIn("Review incomplete", display)
                if present:
                    self.assertTrue(display.endswith(raw))
                else:
                    self.assertIn("missing or invalid", display)
                receipt = (output / "deep-producer.txt").read_text()
                self.assertIn("attempt=2", receipt)
                self.assertIn("validation=failure", receipt)


if __name__ == "__main__":
    unittest.main()
