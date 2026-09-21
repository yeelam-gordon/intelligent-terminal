# Agentic issue intake

`Intelligent Terminal Issue Intake` handles GitHub issues only. It runs on issue
open/edit and meaningful issue-author follow-up, prepares bounded evidence,
uses a small model for classification, then rebuilds and verifies the evidence
before a privileged publisher changes the issue.

Like the localization workflow, responsibilities are split by reuse boundary:

- `.github/workflows/ghaw-issue-triage.md` owns event orchestration, permissions,
  safe-output schema, trusted refresh, and publication.
- `.github/agents/issue-triage.agent.md` is the narrow reusable runtime role.
- `.github/skills/ghaw-issue-triage/SKILL.md` owns the semantic assessment
  procedure and output behavior.
- `.github/scripts/ghaw-issue-triage/triage.py` owns deterministic extraction,
  validation, and rendering, not semantic root-cause reasoning.

## Behavior and trust boundaries

- `.github/scripts/ghaw-issue-triage/config.json` is the explicit mutation
  allowlist. Resolution labels are excluded. The publisher reconciles only the
  managed subset and preserves every other label and existing assignee.
- One marker-bearing comment is created or updated. Input hashes suppress
  unchanged author follow-up and workflow concurrency cancels superseded runs.
- Diagnostic ZIPs are accepted only from GitHub user-attachment URLs. Download,
  entry count, expanded size, per-file size, path, symlink, encryption, and
  compression-ratio checks run before bounded `.log`, `.txt`, or `.json`
  extraction. Common identifiers and credential-shaped values are redacted;
  raw archives never reach the model.
- Required diagnostics that are absent, irrelevant, rejected, or inaccessible
  cap root-cause confidence at low. Absent or inaccessible reports produce a
  direct [Collecting Logs](https://github.com/microsoft/intelligent-terminal#collecting-logs)
  request. A supplied report with no relevant bounded signal instead prompts
  for a concrete correlation detail or routes to maintainers; it is not
  requested again. Features, documentation, questions, and already-sufficient
  reports cannot receive a log request.
- The evidence records a separate `bug_diagnostics_requirement` independent of
  existing type labels. If semantic assessment corrects an untyped or
  mislabeled report to `BUG`, the verifier still enforces the required-log
  confidence and request rules.
- The model cannot write issues. A custom safe-output job refreshes API data,
  verifies the content hash and label/owner allowlists, rejects stale issue
  timestamps, checks assignability again, and performs idempotent publication.
  API or validation failure stops the job; it is never converted to success.

## Ownership configuration

No CODEOWNERS or verified component-owner map existed at implementation time.
`area_owners` and `fallback_owners` therefore default to empty objects/lists.
This intentionally produces a visible configuration gap instead of assigning
or pinging an arbitrary contributor.

Maintainers may add an owner only after confirming responsibility. Each value
must be a GitHub login:

```json
{
  "area_owners": {
    "Area-AgentPane": ["confirmed-owner"]
  },
  "fallback_owners": ["confirmed-triage-maintainer"]
}
```

At runtime the requested owner must also pass GitHub's repository assignee
eligibility endpoint. For maintainer handoff, the verifier deterministically
selects the first currently eligible owner from the selected area's configured
list, then the fallback list, and requires both assignment and the matching
mention. An owner configured only for another area does not suppress the
configuration gap; configured but currently ineligible owners produce a
distinct blocked-routing message. Existing issue assignees are never removed.

## PR mutation constraint

This workflow never edits code or creates commits because it handles issues, not
pull requests. For a future PR workflow, do not ask one agent outcome to both
push a commit and post a review comment. Follow the localization split instead:
the same-repository repair worker has exactly one branch-push/noop outcome,
while the read-only fork guidance worker has exactly one comment/noop outcome.
Any controller coordinates those separate runs and verifies immutable PR heads.

## References and deliberate differences

- [PowerToys issue triage at `e9c2284`](https://github.com/microsoft/PowerToys/blob/e9c22847a3a71d399dc6286d0fc31f3a557d29fc/.github/workflows/issue-triage.md)
  provided the deterministic evidence, fresh-output verification, and canonical
  comment pattern. Its product-label discovery, pin changes, and duplicate
  close-suggestion path are intentionally not used.
- [PowerToys bounded report analyzer at `e9c2284`](https://github.com/microsoft/PowerToys/blob/e9c22847a3a71d399dc6286d0fc31f3a557d29fc/.github/scripts/issue-triage/bug-report-analyzer.py)
  informed archive limits and redaction. Intelligent Terminal uses its own
  generic log names and never exposes raw report content.
- [winget-cli duplicate surfacing at `5b62860`](https://github.com/microsoft/winget-cli/blob/5b62860167520b1503b3880d5a026809eb07c6f4/.github/workflows/duplicate-surfacing.md)
  demonstrates conservative, human-decided duplicate suggestions. Duplicate
  mutation is out of this workflow's scope, so no duplicate or resolution label
  is available.
- [cli/cli issue triage at `0cf1092`](https://github.com/cli/cli/blob/0cf1092493af067646fc5f3db9421c6a6ec9c938/.github/workflows/issue-triage.md)
  separates observations from causal claims and uses label suggestions. This
  repository instead permits verified direct application of its narrow intake
  taxonomy, while forbidding resolution outcomes.
- [spec-kit bug assessment at `d4229c0`](https://github.com/github/spec-kit/blob/d4229c071c7ea3885b43e8a7739847300f618f13/.github/workflows/bug-assess.md)
  is source-grounded but publishes a full root-cause assessment. That is
  rejected here for missing-log cases: intake reports uncertainty and asks for
  specific evidence rather than presenting an unsupported diagnosis.

## Validation

Run focused tests and compile with the repository-pinned gh-aw compiler:

```powershell
python -m unittest discover -s .github\scripts\ghaw-issue-triage\tests -v
gh aw compile ghaw-issue-triage --validate --no-emit
```

The `.md` workflow source is authoring input, not a registered GitHub workflow.
It is intentionally uncompiled and unregistered until maintainers review it and
approve activation. Compile is validation-only for this change; do not emit,
register, or deploy the generated `.lock.yml` workflow until that approval.

`gh aw trial` is not a local agent runner in v0.87.10: it creates or uses a
GitHub trial repository and dispatches Actions. Local semantic evaluation can
instead invoke the repository's `issue-triage` custom agent with bounded
evidence embedded as untrusted prompt data and built-in GitHub MCP access
disabled. If delegated checks are requested, Copilot CLI may print child
responses before the parent's final response; only the final complete object
whose hash matches the evidence may be wrapped as the safe-output item and
passed through `triage.py verify`. Direct `--fleet` output is advisory and must
never be published because it contains multiple independent responses rather
than one authoritative safe output.
