---
name: Intelligent Terminal Issue Intake
description: Classify issues, request only actionable missing evidence, and publish one verified canonical triage card.
on:
  issues:
    types: [opened, edited]
  issue_comment:
    types: [created]
  roles: all
  skip-bots: [github-actions, copilot, dependabot]

concurrency:
  group: ghaw-issue-triage-${{ github.event.issue.number }}
  cancel-in-progress: true

engine:
  id: copilot
imports:
  - .github/agents/issue-triage.agent.md
model: small
max-turns: 8
max-ai-credits: 20
max-daily-ai-credits: 500
timeout-minutes: 15
if: >-
  github.event_name != 'issue_comment' ||
  (
    !github.event.issue.pull_request &&
    github.event.comment.user.login == github.event.issue.user.login
  )

permissions:
  contents: read
  issues: read
  copilot-requests: write

checkout:
  ref: ${{ github.workflow_sha }}

steps:
  - name: Prepare bounded issue evidence
    id: prepare
    env:
      GITHUB_TOKEN: ${{ github.token }}
      GH_AW_SAFE_OUTPUTS: ${{ runner.temp }}/gh-aw/safeoutputs/outputs.jsonl
    run: >-
      python .github/scripts/ghaw-issue-triage/triage.py prepare
      --event "$GITHUB_EVENT_PATH"
      --config .github/scripts/ghaw-issue-triage/config.json
      --context /tmp/gh-aw/issue-context.md
      --evidence /tmp/gh-aw/issue-evidence.json

pre-agent-steps:
  - name: Gate agent on deterministic preprocessing
    if: steps.prepare.outputs.should_process != 'true'
    run: |
      echo "Deterministic preprocessing skipped agent execution."
      exit 1

safe-outputs:
  report-failure-as-issue: false
  report-failed-jobs: false
  report-incomplete:
    create-issue: false
  noop:
    report-as-issue: false
  jobs:
    publish-issue-triage:
      description: Verify fresh issue evidence, reconcile managed labels, optionally assign a configured owner, and upsert the canonical triage card.
      runs-on: ubuntu-latest
      permissions:
        contents: read
        issues: write
      inputs:
        input_sha256:
          description: Exact input SHA-256 from deterministic evidence.
          required: true
          type: string
        issue_type:
          description: Classified issue type.
          required: true
          type: choice
          options: [BUG, DOCUMENTATION, FEATURE, QUESTION]
        type_confidence:
          description: Confidence in issue type.
          required: true
          type: choice
          options: [HIGH, MEDIUM, LOW, NONE]
        area_label:
          description: Exact deterministic Area-* candidate or None.
          required: true
          type: string
        area_confidence:
          description: Confidence in affected area.
          required: true
          type: choice
          options: [HIGH, MEDIUM, LOW, NONE]
        agent_label:
          description: Exact deterministic Agent-* candidate or None.
          required: true
          type: string
        root_cause:
          description: Evidence-grounded cause or explicit statement that it is unknown.
          required: true
          type: string
        root_cause_confidence:
          description: Confidence in root cause.
          required: true
          type: choice
          options: [HIGH, MEDIUM, LOW, NONE]
        ownership_confidence:
          description: Confidence in configured ownership.
          required: true
          type: choice
          options: [HIGH, MEDIUM, LOW, NONE]
        labels_json:
          description: JSON array of desired labels from the deterministic allowlist.
          required: true
          type: string
        disposition:
          description: Whether the next action belongs to the author or maintainers.
          required: true
          type: choice
          options: [REQUEST_AUTHOR, MAINTAINER_REVIEW]
        author_request:
          description: One specific actionable request, or None for maintainer review.
          required: true
          type: string
        summary:
          description: Concise established facts.
          required: true
          type: string
        maintainer_summary:
          description: Established facts, uncertainty, and why maintainer review is next.
          required: true
          type: string
        assignee:
          description: Configured eligible owner or None.
          required: true
          type: string
        mentions_json:
          description: JSON array of configured eligible maintainers to mention.
          required: true
          type: string
        next_steps_json:
          description: JSON array containing one to five concrete maintainer next steps.
          required: true
          type: string
      steps:
        - name: Check out trusted workflow source
          uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
          with:
            ref: ${{ github.workflow_sha }}
            persist-credentials: false
        - name: Rebuild current deterministic evidence
          env:
            GITHUB_TOKEN: ${{ github.token }}
          run: >-
            python .github/scripts/ghaw-issue-triage/triage.py prepare
            --force
            --event "$GITHUB_EVENT_PATH"
            --config .github/scripts/ghaw-issue-triage/config.json
            --context "$RUNNER_TEMP/current-issue-context.md"
            --evidence "$RUNNER_TEMP/current-issue-evidence.json"
        - name: Verify the model output against current evidence
          run: >-
            python .github/scripts/ghaw-issue-triage/triage.py verify
            --agent-output "$GH_AW_AGENT_OUTPUT"
            --evidence "$RUNNER_TEMP/current-issue-evidence.json"
            --config .github/scripts/ghaw-issue-triage/config.json
            --output "$RUNNER_TEMP/verified-issue-triage.json"
        - name: Render the canonical triage card
          run: >-
            python .github/scripts/ghaw-issue-triage/triage.py render
            --verified "$RUNNER_TEMP/verified-issue-triage.json"
            --output "$RUNNER_TEMP/issue-triage-comment.md"
        - name: Publish verified issue intake
          uses: actions/github-script@3a2844b7e9c422d3c10d287c895573f7108da1b3 # v9.0.0
          env:
            VERIFIED_TRIAGE: ${{ runner.temp }}/verified-issue-triage.json
            TRIAGE_COMMENT: ${{ runner.temp }}/issue-triage-comment.md
          with:
            script: |
              const fs = require('fs');
              const verified = JSON.parse(fs.readFileSync(process.env.VERIFIED_TRIAGE, 'utf8'));
              const body = fs.readFileSync(process.env.TRIAGE_COMMENT, 'utf8');
              const marker = '<!-- intelligent-terminal-ai-triage:canonical:v1 -->';
              const issueNumber = verified.issue_number;

              const readIssue = async () => {
                const response = await github.rest.issues.get({
                  ...context.repo,
                  issue_number: issueNumber
                });
                if (response.data.pull_request) {
                  throw new Error('The target is a pull request, not an issue.');
                }
                if (response.data.state !== 'open') {
                  throw new Error('The issue closed before publication.');
                }
                return response.data;
              };

              const assertFresh = (issue) => {
                if (verified.issue_updated_at &&
                    issue.updated_at !== verified.issue_updated_at) {
                  throw new Error(
                    `Stale triage rejected: issue changed at ${issue.updated_at} after evidence ${verified.issue_updated_at}.`
                  );
                }
              };

              let current = await readIssue();
              assertFresh(current);

              const managed = new Set(verified.managed_labels);
              const desired = new Set(verified.desired_managed_labels);
              const currentLabels = new Set(current.labels.map(label => label.name));
              const toAdd = [...desired].filter(label => !currentLabels.has(label));
              const toRemove = [...currentLabels].filter(
                label => managed.has(label) && !desired.has(label)
              );

              if (toAdd.length) {
                await github.rest.issues.addLabels({
                  ...context.repo,
                  issue_number: issueNumber,
                  labels: toAdd
                });
              }
              for (const name of toRemove) {
                try {
                  await github.rest.issues.removeLabel({
                    ...context.repo,
                    issue_number: issueNumber,
                    name
                  });
                } catch (error) {
                  if (error.status !== 404) throw error;
                }
              }

              if (verified.assignee !== 'None') {
                const assigneeCheck = await github.request(
                  'GET /repos/{owner}/{repo}/assignees/{assignee}',
                  { ...context.repo, assignee: verified.assignee }
                );
                if (assigneeCheck.status !== 204) {
                  throw new Error('Configured assignee is no longer eligible.');
                }
                current = await readIssue();
                if (!current.assignees.some(user => user.login === verified.assignee)) {
                  await github.rest.issues.addAssignees({
                    ...context.repo,
                    issue_number: issueNumber,
                    assignees: [verified.assignee]
                  });
                }
              }

              const comments = await github.paginate(
                github.rest.issues.listComments,
                { ...context.repo, issue_number: issueNumber, per_page: 100 }
              );
              const canonical = comments
                .filter(comment =>
                  comment.user?.login === 'github-actions[bot]' &&
                  typeof comment.body === 'string' &&
                  comment.body.includes(marker)
                )
                .sort((left, right) => left.id - right.id)[0];

              current = await readIssue();
              assertFresh(current);
              if (canonical) {
                await github.rest.issues.updateComment({
                  ...context.repo,
                  comment_id: canonical.id,
                  body
                });
              } else {
                await github.rest.issues.createComment({
                  ...context.repo,
                  issue_number: issueNumber,
                  body
                });
              }
---

# Intelligent Terminal issue intake

Imported runtime role: `Issue Triage Specialist`.

Read `/tmp/gh-aw/issue-context.md` exactly once, then follow
`.github/skills/ghaw-issue-triage/SKILL.md`. The caller has already bounded and
redacted issue evidence and owns all mutation checks.

If preprocessing says execution was skipped, emit no output because the
deterministic `noop` is already queued. Otherwise call
`publish_issue_triage` exactly once using its runtime schema. Do not call any
other output.
