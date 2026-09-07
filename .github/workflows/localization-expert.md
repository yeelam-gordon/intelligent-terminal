---
description: 'Review and complete customer-facing localization changes in same-repo pull requests'
intent: 'Use one deterministic PowerShell validator, then repair only the reported localization defects.'

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
  ref: ${{ github.event.inputs.expected_head_sha }}
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
    - 'git add:*'
    - 'git commit:*'
    - 'pwsh:*'

jobs:
  prepare:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
      pull-requests: read
    outputs:
      already_complete: ${{ steps.prepare.outputs.already_complete }}
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
      - name: Validate immutable PR head and deterministic checks
        id: prepare
        shell: pwsh
        env:
          PR_NUMBER: ${{ github.event.inputs.pr_number }}
          BASE_SHA: ${{ github.event.inputs.expected_base_sha }}
          HEAD_SHA: ${{ github.event.inputs.expected_head_sha }}
          REPOSITORY: ${{ github.repository }}
        run: |
          $ErrorActionPreference = 'Stop'
          $remoteRef = "refs/remotes/origin/localization-pr-$env:PR_NUMBER"
          git fetch --no-tags origin "+refs/pull/$env:PR_NUMBER/head:$remoteRef"
          $currentHead = (git rev-parse $remoteRef).Trim()
          if ($currentHead -ne $env:HEAD_SHA) {
            throw "PR head changed after controller dispatch. Expected $env:HEAD_SHA, found $currentHead."
          }

          $alreadyComplete = 'false'
          if ((git log -1 --pretty=%s $env:HEAD_SHA) -match '\[localization-expert\]$') {
            $commit = gh api "repos/$env:REPOSITORY/commits/$env:HEAD_SHA" | ConvertFrom-Json -AsHashtable
            $authorLogin = $commit.author.login
            $committerLogin = $commit.committer.login
            $verified = [bool]$commit.commit.verification.verified
            $parentCount = @($commit.parents).Count
            if ($authorLogin -eq 'github-actions[bot]' -and $committerLogin -eq 'web-flow' -and $verified -and $parentCount -eq 1) {
              $alreadyComplete = 'true'
            }
          }

          $jsonl = Join-Path $PWD 'localization-expert.validate.jsonl'
          & .github/scripts/localization_checks.ps1 -Mode Validate -PullRequestNumber $env:PR_NUMBER -BaseRevision $env:BASE_SHA -HeadRevision $env:HEAD_SHA | Tee-Object -FilePath $jsonl | Out-Null
          $exitCode = $LASTEXITCODE
          if (@(0, 20, 30) -notcontains $exitCode) {
            throw "Unexpected localization validator exit code: $exitCode"
          }
          $summary = Get-Content -LiteralPath $jsonl | Select-Object -Last 1 | ConvertFrom-Json -AsHashtable
          if ($summary.kind -ne 'summary') {
            throw 'Localization validator did not emit a summary record.'
          }

          "already_complete=$alreadyComplete" >> $env:GITHUB_OUTPUT
          "comparison_base=$($summary.comparison_base)" >> $env:GITHUB_OUTPUT
          "initial_status=$($summary.status)" >> $env:GITHUB_OUTPUT
          "initial_action=$($summary.action)" >> $env:GITHUB_OUTPUT

  agent:
    needs: [prepare]
    if: needs.prepare.outputs.already_complete != 'true'

safe-outputs:
  push-to-pull-request-branch:
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
max-turns: 70
max-ai-credits: 1000
max-daily-ai-credits: 5000
concurrency:
  group: 'localization-expert-${{ github.event.inputs.pr_number }}'
  job-discriminator: ${{ github.run_id }}
  cancel-in-progress: false
run-name: 'Localization Expert ${{ github.event.inputs.dispatch_id }}'
---

Same-repo localization repair for pull request #${{ github.event.inputs.pr_number }} in
`${{ github.event.inputs.repo }}`.

Deterministic context:
- immutable base: `${{ github.event.inputs.expected_base_sha }}`
- immutable head: `${{ github.event.inputs.expected_head_sha }}`
- comparison base used by the validator: `${{ needs.prepare.outputs.comparison_base }}`
- initial validator summary: `${{ needs.prepare.outputs.initial_status }}` /
  `${{ needs.prepare.outputs.initial_action }}`

Required flow:
1. Run `pwsh .github/scripts/localization_checks.ps1 -Mode Validate -PullRequestNumber "${{ github.event.inputs.pr_number }}" -BaseRevision "${{ github.event.inputs.expected_base_sha }}"` before editing. Treat exit `20` as fixable findings and exit `30` as escalation.
2. Fix only the reported localization files and resources. Rerun validation until it exits `0` or remains `30`.
3. Invoke `localization-review-gate` exactly once per final candidate. It must return explicit `PASS` or `FAIL`.
4. If deterministic validation passes and the reviewer returns `PASS` without requiring edits, post one concise success comment and make no commit.
5. If edits were required, stage only the allowed localization files, create one completion commit whose subject ends with `[localization-expert]`, and push it with a safe-output message that also ends with `[localization-expert]`.
6. If validation or the independent reviewer stays blocked or fails, do not push partial work. Post one concise escalation comment citing each unresolved `check_id`, file, resource, and suggested action.

Never modify files under `.github/` from this workflow.

## agent: `localization-review-gate`

---
description: 'Performs the independent final localization review for the same-repo workflow'
---

{{#runtime-import .github/agents/localization-reviewer.agent.md}}

## end agent: `localization-review-gate`
