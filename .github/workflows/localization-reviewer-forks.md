---
description: 'Review customer-facing localization changes from fork pull requests'
intent: 'Validate fork localization changes read-only without checking out or executing fork code.'

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
  fetch-depth: 0

tools:
  edit: false
  bash:
    - 'git fetch:*'
    - 'git rev-parse:*'
    - 'pwsh:*'
  cli-proxy: false
  github:
    toolsets: [pull_requests]

jobs:
  prepare:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
    outputs:
      comparison_base: ${{ steps.prepare.outputs.comparison_base }}
      initial_status: ${{ steps.prepare.outputs.initial_status }}
      initial_action: ${{ steps.prepare.outputs.initial_action }}
    steps:
      - name: Checkout trusted base
        uses: actions/checkout@v7
        with:
          ref: ${{ github.event.inputs.expected_base_sha }}
          fetch-depth: 0
          persist-credentials: true
      - name: Validate immutable fork head without checkout
        id: prepare
        shell: pwsh
        env:
          PR_NUMBER: ${{ github.event.inputs.pr_number }}
          BASE_SHA: ${{ github.event.inputs.expected_base_sha }}
          HEAD_SHA: ${{ github.event.inputs.expected_head_sha }}
        run: |
          $ErrorActionPreference = 'Stop'
          $remoteRef = "refs/remotes/origin/localization-pr-$env:PR_NUMBER"
          git fetch --no-tags origin "+refs/pull/$env:PR_NUMBER/head:$remoteRef"
          $currentHead = (git rev-parse $remoteRef).Trim()
          if ($currentHead -ne $env:HEAD_SHA) {
            throw "Fork PR head changed after controller dispatch. Expected $env:HEAD_SHA, found $currentHead."
          }

          $jsonl = Join-Path $PWD 'localization-reviewer-forks.validate.jsonl'
          & .github/scripts/localization_checks.ps1 -Mode Validate -PullRequestNumber $env:PR_NUMBER -BaseRevision $env:BASE_SHA -HeadRevision $env:HEAD_SHA | Tee-Object -FilePath $jsonl | Out-Null
          $exitCode = $LASTEXITCODE
          if (@(0, 20, 30) -notcontains $exitCode) {
            throw "Unexpected localization validator exit code: $exitCode"
          }
          $summary = Get-Content -LiteralPath $jsonl | Select-Object -Last 1 | ConvertFrom-Json -AsHashtable
          if ($summary.kind -ne 'summary') {
            throw 'Localization validator did not emit a summary record.'
          }

          "comparison_base=$($summary.comparison_base)" >> $env:GITHUB_OUTPUT
          "initial_status=$($summary.status)" >> $env:GITHUB_OUTPUT
          "initial_action=$($summary.action)" >> $env:GITHUB_OUTPUT

  agent:
    needs: [prepare]

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

Fork localization review for pull request #${{ github.event.inputs.pr_number }} in
`${{ github.event.inputs.repo }}`.

The workspace remains on trusted base `${{ github.event.inputs.expected_base_sha }}`.
Do not check out or execute fork code. If you need immutable fork content for the
shared validator, fetch the pull request head into a detached remote ref only and
inspect it through Git objects.

Deterministic context:
- immutable fork head: `${{ github.event.inputs.expected_head_sha }}`
- comparison base used by the validator: `${{ needs.prepare.outputs.comparison_base }}`
- initial validator summary: `${{ needs.prepare.outputs.initial_status }}` /
  `${{ needs.prepare.outputs.initial_action }}`

Required flow:
1. Use `pwsh .github/scripts/localization_checks.ps1 -Mode Validate -PullRequestNumber "${{ github.event.inputs.pr_number }}" -BaseRevision "${{ github.event.inputs.expected_base_sha }}" -HeadRevision "${{ github.event.inputs.expected_head_sha }}"` for deterministic read-only checks.
2. Use GitHub pull-request tools for human-readable diff context and review comments.
3. Return a concise visible `PASS` or actionable `FAIL` comment. Every failure must cite `check_id`, file, resource, observed problem, expected result, and suggested action.
4. Never push, never edit files, and never claim a check passed if you could not actually observe it.
