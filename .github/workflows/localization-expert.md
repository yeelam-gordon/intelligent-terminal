---
description: 'Review and complete customer-facing localization changes in pull requests'
intent: 'Prevent incomplete or incorrect localized UI text from reaching customers.'

on:
  workflow_dispatch:
    inputs:
      dispatch_id:
        description: 'Controller correlation identifier'
        required: true
        type: string
      pr_number:
        description: 'Pull request number'
        required: true
        type: string
      repo:
        description: 'Target owner/repository'
        required: true
        type: string
      expected_head_sha:
        description: 'Immutable pull request head reviewed by the controller'
        required: true
        type: string
      expected_base_sha:
        description: 'Pull request base commit'
        required: true
        type: string
      head_ref:
        description: 'Pull request head branch'
        required: true
        type: string
      base_ref:
        description: 'Pull request base branch'
        required: true
        type: string
      head_repo:
        description: 'Pull request head repository'
        required: true
        type: string
      same_repo:
        description: 'Whether the head repository is the workflow repository'
        required: true
        type: string

permissions:
  contents: read
  pull-requests: read
  copilot-requests: write

engine: copilot
imports:
  - .github/agents/localization-expert.agent.md

checkout:
  fetch-depth: 0

network:
  allowed:
    - defaults
    - rust
    - 'learn.microsoft.com'

tools:
  edit:
  bash:
    - 'git status:*'
    - 'git diff:*'
    - 'git log:*'
    - 'node:*'
    - 'python3:*'
    - 'cargo:*'

jobs:
  localization_content_gate:
    if: github.event.inputs.same_repo == 'true'
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
    outputs:
      should_run: ${{ steps.finalize.outputs.should_run }}
      merge_base: ${{ steps.finalize.outputs.merge_base }}
    steps:
      - name: Validate workflow_dispatch inputs
        shell: bash
        env:
          PR_NUMBER: ${{ github.event.inputs.pr_number }}
          EXPECTED_BASE_SHA: ${{ github.event.inputs.expected_base_sha }}
          EXPECTED_HEAD_SHA: ${{ github.event.inputs.expected_head_sha }}
        run: |
          set -euo pipefail
          if [[ ! "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
            echo "::error::Invalid workflow_dispatch input 'pr_number'; expected a positive decimal integer."
            exit 1
          fi

          if [[ ! "$EXPECTED_BASE_SHA" =~ ^[0-9a-fA-F]{40}$ ]]; then
            echo "::error::Invalid workflow_dispatch input 'expected_base_sha'; expected exactly 40 hexadecimal characters."
            exit 1
          fi

          if [[ ! "$EXPECTED_HEAD_SHA" =~ ^[0-9a-fA-F]{40}$ ]]; then
            echo "::error::Invalid workflow_dispatch input 'expected_head_sha'; expected exactly 40 hexadecimal characters."
            exit 1
          fi
      - name: Checkout repository
        uses: actions/checkout@v7
        with:
          ref: ${{ github.event.inputs.expected_base_sha }}
          fetch-depth: 0
          persist-credentials: true
      - name: Classify localization content changes
        id: classify
        shell: bash
        env:
          GH_TOKEN: ${{ github.token }}
          BASE_SHA: ${{ github.event.inputs.expected_base_sha }}
          HEAD_SHA: ${{ github.event.inputs.expected_head_sha }}
          PR_NUMBER: ${{ github.event.inputs.pr_number }}
        run: |
          set -euo pipefail
          remote_ref="refs/remotes/origin/localization-pr-${PR_NUMBER}"
          git fetch --no-tags origin "+refs/pull/${PR_NUMBER}/head:${remote_ref}"
          current_head="$(git rev-parse "$remote_ref")"
          if [ "$current_head" != "$HEAD_SHA" ]; then
            echo "::error::PR head changed after controller dispatch. Expected $HEAD_SHA, found $current_head."
            exit 1
          fi

          if git log -1 --pretty=%s "$HEAD_SHA" | grep -Eq '\[localization-expert\]$'; then
            author_login="$(gh api "repos/$GITHUB_REPOSITORY/commits/$HEAD_SHA" --jq '.author.login // ""')"
            committer_login="$(gh api "repos/$GITHUB_REPOSITORY/commits/$HEAD_SHA" --jq '.committer.login // ""')"
            verified="$(gh api "repos/$GITHUB_REPOSITORY/commits/$HEAD_SHA" --jq '.commit.verification.verified')"
            parent_count="$(gh api "repos/$GITHUB_REPOSITORY/commits/$HEAD_SHA" --jq '.parents | length')"
            if [ "$author_login" = "github-actions[bot]" ] &&
               [ "$committer_login" = "web-flow" ] &&
               [ "$verified" = "true" ] &&
               [ "$parent_count" = "1" ]; then
              echo "should_run=false" >> "$GITHUB_OUTPUT"
              echo "Skipping: HEAD_SHA ($HEAD_SHA) is the verified Localization Expert completion commit." >> "$GITHUB_STEP_SUMMARY"
              exit 0
            fi
          fi

          if ! MERGE_BASE="$(git merge-base "$BASE_SHA" "$HEAD_SHA")"; then
            echo "merge_base=$BASE_SHA" >> "$GITHUB_OUTPUT"
            echo "should_run=true" >> "$GITHUB_OUTPUT"
            echo "Classification failed while resolving the merge base; running Localization Expert as a fail-open review." >> "$GITHUB_STEP_SUMMARY"
            exit 0
          fi
          echo "merge_base=$MERGE_BASE" >> "$GITHUB_OUTPUT"

          classification_failed=false
          if ! should_run="$(python3 .github/scripts/localization_content_gate.py "$MERGE_BASE" "$HEAD_SHA")"; then
            should_run=true
            classification_failed=true
          fi

          if [ "$should_run" != "true" ] && [ "$should_run" != "false" ]; then
            should_run=true
            classification_failed=true
          fi

          echo "should_run=$should_run" >> "$GITHUB_OUTPUT"
          if [ "$classification_failed" = "true" ]; then
            echo "Semantic classification failed; running Localization Expert as a fail-open review." >> "$GITHUB_STEP_SUMMARY"
          elif [ "$should_run" != "true" ]; then
            echo "Skipping: resource files changed in the pull request, but their localization entries are semantically unchanged." >> "$GITHUB_STEP_SUMMARY"
          fi
      - name: Finalize localization gate outputs
        id: finalize
        if: always()
        shell: bash
        env:
          BASE_SHA: ${{ github.event.inputs.expected_base_sha }}
          CLASSIFY_OUTCOME: ${{ steps.classify.outcome }}
          CLASSIFIED_MERGE_BASE: ${{ steps.classify.outputs.merge_base }}
          CLASSIFIED_SHOULD_RUN: ${{ steps.classify.outputs.should_run }}
        run: |
          if [ "$CLASSIFY_OUTCOME" != "success" ]; then
            echo "::error::Localization provenance validation failed; refusing to run against an unverified PR head."
            exit 1
          fi
          merge_base="${CLASSIFIED_MERGE_BASE:-$BASE_SHA}"
          should_run="$CLASSIFIED_SHOULD_RUN"
          if [ "$should_run" != "true" ] && [ "$should_run" != "false" ]; then
            echo "::error::Localization gate did not produce a valid verdict."
            exit 1
          fi
          echo "merge_base=$merge_base" >> "$GITHUB_OUTPUT"
          echo "should_run=$should_run" >> "$GITHUB_OUTPUT"

  agent:
    needs: [localization_content_gate]
    if: needs.localization_content_gate.outputs.should_run == 'true'

safe-outputs:
  push-to-pull-request-branch:
    # The handler uses this immutable baseline for the agent-only incremental
    # patch. A branch name would collide with the destination branch, while the
    # default base branch would make allowed-files inspect the developer's
    # pre-existing source commits.
    base-branch: ${{ github.event.inputs.expected_head_sha }}
    allowed-files:
      - 'src/cascadia/**/Resources/*.resw'
      - 'src/cascadia/**/Resources/**/*.resw'
      - 'tools/wta/locales/*.yml'
    protected-files: blocked
    fallback-as-pull-request: false
  add-comment:
    target: triggering
    max: 1
    hide-older-comments: true

timeout-minutes: 45
max-turns: 80
max-ai-credits: 1000
max-daily-ai-credits: 5000
concurrency:
  group: 'localization-expert-${{ github.event.inputs.pr_number }}'
  job-discriminator: ${{ github.run_id }}
  cancel-in-progress: false
run-name: 'Localization Expert ${{ github.event.inputs.dispatch_id }}'
---

Review pull request #${{ github.event.inputs.pr_number }} in
`${{ github.event.inputs.repo }}` as the Localization
Expert.

Before doing localization work, verify that both authoritative instruction
files and the `localization-review-gate` sub-agent are available. If an
instruction file is unavailable, use `missing_data` and stop. If the reviewer
agent or agent invocation tool is unavailable or fails to return explicit
`PASS`/`FAIL`, use `missing_tool` and stop. Never push or report success by
self-reviewing.

A deterministic `localization_content_gate` job has already run before this agent
job was scheduled. It compared the pull request head with merge base
`${{ needs.localization_content_gate.outputs.merge_base }}` and
either detected meaningful `.resw` or WTA locale YAML localization changes or
failed open because it could not classify the diff safely. This agent job only
runs when that gate reports `should_run == 'true'`. Independently verify the
committed pull request diff, including whether the head is already this
workflow's own completion commit, then follow the imported agent instructions
exactly.
The immutable committed pull request tip is
`${{ github.event.inputs.expected_head_sha }}`. Use that SHA, not checkout `HEAD`,
for the committed PR diff because GitHub may check out a synthetic merge commit.
Do not fetch or create additional PR refs.

If localization is already complete and the independent Localization Reviewer
returns `PASS`, make no commit. Use `add_comment` once to post a concise,
human-visible success report on the pull request containing:

- the source-language keys reviewed;
- the applicable locale count;
- the validations that passed;
- `Independent Localization Reviewer: PASS`;
- `No localization changes were required.`

Do not use `noop` for this already-complete path because its message is visible
only in workflow logs, not in the pull request conversation.

If localization is missing or defective, complete or correct it, run the required
validation, obtain a final `PASS` from the independent Localization Reviewer, then:

1. Commit only the allowed localization resource files. End the commit subject
   with `[localization-expert]` so a token-independent guard can recognize the
   workflow-authored completion commit.
   Stage only explicit localization pathspecs; never use `git add -A`,
   `git add .`, or `git commit -a`, because the runtime contains an untracked
   inline reviewer file and may contain temporary validation scripts.
2. Use `push_to_pull_request_branch` to append that commit to the triggering pull
   request branch. Its `message` argument must itself end with
   `[localization-expert]`; do not rely only on the local commit subject.

When making an incremental correction, keep the diff as small as correctness
allows: do not rewrite existing source comments, translated values, or unrelated
entries that are already correct. Only touch the newly missing or defective key
and any directly required neighboring text.

If a finding cannot be fixed safely, do not push a partial result. Use
`add_comment` once with the exact unresolved findings and required human action.

Never modify files under `.github/`. During normal classification, the
`localization_content_gate` job skips the workflow's own
`[localization-expert]` completion commit and resource-file-only changes with no
localizable entry changes before AI inference. Recoverable classification
errors deliberately fail open; unrecoverable runner cancellation or job timeout
fails closed. The trigger skips only GitHub Actions completion commits;
Copilot-authored feature pull requests remain eligible for review.

## agent: `localization-review-gate`

---
description: 'Independently reviews customer-facing localization changes'
---

Read `.github/agents/localization-reviewer.agent.md` and follow the entire agent
specification. Perform the requested review as a read-only independent reviewer
and return its required `PASS` or `FAIL` result. Do not delegate this review.
GHAW materializes this inline sub-agent as the untracked runtime file
`.github/agents/localization-review-gate.agent.md`; ignore that exact file when
checking worktree cleanliness because it is framework infrastructure, not a pull
request or Localization Expert change.
Do not edit, create, delete, stage, commit, or push any file.
