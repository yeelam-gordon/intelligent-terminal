---
description: 'Review customer-facing localization changes from fork pull requests'
intent: 'Give external contributors safe localization feedback without executing or modifying fork code.'

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
  - .github/agents/localization-reviewer.agent.md

checkout:
  repository: ${{ github.repository }}
  ref: ${{ github.event.inputs.expected_base_sha }}

tools:
  edit: false
  bash: []
  cli-proxy: false
  github:
    toolsets: [pull_requests]

jobs:
  localization_content_gate:
    if: github.event.inputs.same_repo == 'false'
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
    outputs:
      should_run: ${{ steps.finalize.outputs.should_run }}
      merge_base: ${{ steps.finalize.outputs.merge_base }}
    steps:
      - name: Checkout trusted base
        uses: actions/checkout@v7
        with:
          ref: ${{ github.event.inputs.expected_base_sha }}
          fetch-depth: 0
          persist-credentials: true
      - name: Classify localization content changes
        id: classify
        shell: bash
        env:
          BASE_SHA: ${{ github.event.inputs.expected_base_sha }}
          HEAD_SHA: ${{ github.event.inputs.expected_head_sha }}
          PR_NUMBER: ${{ github.event.inputs.pr_number }}
        run: |
          set -euo pipefail
          remote_ref="refs/remotes/origin/localization-pr-${PR_NUMBER}"
          git fetch --no-tags origin "+refs/pull/${PR_NUMBER}/head:${remote_ref}"
          current_head="$(git rev-parse "$remote_ref")"
          if [ "$current_head" != "$HEAD_SHA" ]; then
            echo "::error::Fork PR head changed after controller dispatch. Expected $HEAD_SHA, found $current_head."
            exit 1
          fi

          if ! MERGE_BASE="$(git merge-base "$BASE_SHA" "$HEAD_SHA")"; then
            echo "merge_base=$BASE_SHA" >> "$GITHUB_OUTPUT"
            echo "should_run=true" >> "$GITHUB_OUTPUT"
            echo "Classification failed while resolving the merge base; running Localization Reviewer as a fail-open review." >> "$GITHUB_STEP_SUMMARY"
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
            echo "Semantic classification failed; running Localization Reviewer as a fail-open review." >> "$GITHUB_STEP_SUMMARY"
          elif [ "$should_run" != "true" ]; then
            echo "Skipping: fork resource files changed, but their localization entries are semantically unchanged." >> "$GITHUB_STEP_SUMMARY"
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
            echo "::error::Fork localization provenance validation failed; refusing to review an unverified PR head."
            exit 1
          fi
          merge_base="${CLASSIFIED_MERGE_BASE:-$BASE_SHA}"
          should_run="$CLASSIFIED_SHOULD_RUN"
          if [ "$should_run" != "true" ] && [ "$should_run" != "false" ]; then
            echo "::error::Fork localization gate did not produce a valid verdict."
            exit 1
          fi
          echo "merge_base=$merge_base" >> "$GITHUB_OUTPUT"
          echo "should_run=$should_run" >> "$GITHUB_OUTPUT"

  agent:
    needs: [localization_content_gate]
    if: needs.localization_content_gate.outputs.should_run == 'true'

safe-outputs:
  add-comment:
    target: '*'
    max: 1
    hide-older-comments: true

timeout-minutes: 30
max-turns: 30
max-ai-credits: 500
max-daily-ai-credits: 2500
concurrency:
  group: 'localization-reviewer-fork-${{ github.event.inputs.pr_number }}'
  job-discriminator: ${{ github.run_id }}
  cancel-in-progress: true
run-name: 'Localization Reviewer Fork ${{ github.event.inputs.dispatch_id }}'
---

Review localization changes in fork pull request
#${{ github.event.inputs.pr_number }} in `${{ github.event.inputs.repo }}` as the
imported Localization Reviewer.

A deterministic content gate compared the fork head with merge base
`${{ needs.localization_content_gate.outputs.merge_base }}` before scheduling
this agent.

This is a detached `workflow_dispatch` run. The workspace contains only the
trusted base commit `${{ github.event.inputs.expected_base_sha }}`. Do not check
out, execute, edit, or import files from the pull request head. Inspect pull
request #${{ github.event.inputs.pr_number }} in
`${{ github.event.inputs.repo }}` only through the read-only GitHub tools.
This is explicitly an API-only fork review for the purposes of the imported
Localization Reviewer instructions.

Apply both authoritative instruction files from the trusted base branch:

- `.github/instructions/localization.instructions.md`
- `.github/instructions/rust-localization.instructions.md`

Because GitHub's API diff does not expose original file bytes or a complete
checkout of the fork head, BOM preservation, full-file XML/YAML parsing, and
whole-tree key parity are not verifiable in this workflow. Do not claim those
checks passed and do not fail solely because they are unavailable. State the
limitation in the review evidence and ask maintainers to confirm those checks
before merge.

If the localization is complete and correct, use `add_comment` once with a
concise visible `PASS` report. If it is missing or defective, use `add_comment`
once with actionable findings: the resource key, affected locale scope, exact
rule violated, and the changes the contributor must make. Every `add_comment`
call must explicitly set `item_number` to
`${{ github.event.inputs.pr_number }}` and `repo` to
`${{ github.event.inputs.repo }}`. Never attempt to push to a contributor-owned
fork.
