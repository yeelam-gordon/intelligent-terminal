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
          function Get-ValidatedPrepareInputs {
            if ($env:PR_NUMBER -notmatch '^[1-9][0-9]*$') {
              throw "Invalid PR_NUMBER '$env:PR_NUMBER'; expected a positive decimal integer."
            }
            if ($env:BASE_SHA -notmatch '^[0-9a-fA-F]{40}$') {
              throw "Invalid BASE_SHA '$env:BASE_SHA'; expected exactly 40 hexadecimal characters."
            }
            if ($env:HEAD_SHA -notmatch '^[0-9a-fA-F]{40}$') {
              throw "Invalid HEAD_SHA '$env:HEAD_SHA'; expected exactly 40 hexadecimal characters."
            }

            return @{
              PrNumber = $env:PR_NUMBER
              BaseSha = $env:BASE_SHA.ToLowerInvariant()
              HeadSha = $env:HEAD_SHA.ToLowerInvariant()
            }
          }

          $inputs = Get-ValidatedPrepareInputs
          $remoteRef = "refs/remotes/origin/localization-pr-$($inputs.PrNumber)"
          git fetch --no-tags origin "+refs/pull/$($inputs.PrNumber)/head:$remoteRef"
          $currentHead = (git rev-parse $remoteRef).Trim().ToLowerInvariant()
          if ($currentHead -ne $inputs.HeadSha) {
            throw "Fork PR head changed after controller dispatch. Expected $($inputs.HeadSha), found $currentHead."
          }

          $jsonl = Join-Path $PWD 'localization-reviewer-forks.validate.jsonl'
          & .github/scripts/localization_checks.ps1 -Mode Validate -PullRequestNumber $inputs.PrNumber -BaseRevision $inputs.BaseSha -HeadRevision $inputs.HeadSha | Tee-Object -FilePath $jsonl | Out-Null
          $exitCode = $LASTEXITCODE
          . (Join-Path $PWD '.github/scripts/localization_validator_output.ps1')
          $completion = Resolve-LocalizationValidatorCompletion -JsonlPath $jsonl -ExitCode $exitCode -AllowedExitCodes @(0, 20, 30, 64)
          $summary = $completion.Summary

          "comparison_base=$($summary.comparison_base)" >> $env:GITHUB_OUTPUT
          "initial_status=$($summary.status)" >> $env:GITHUB_OUTPUT
          "initial_action=$($summary.action)" >> $env:GITHUB_OUTPUT

  agent:
    needs: [prepare]
    if: needs.prepare.outputs.initial_action != 'ESCALATE'

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
5. If the validator reports exit `64`, surface the blocked invalid-input summary instead of treating it as an unexpected failure.
