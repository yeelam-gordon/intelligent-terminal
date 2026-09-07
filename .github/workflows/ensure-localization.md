---
description: 'Detached same-repo localization repair worker; validates, fixes, and requests final review. Dispatched by ensure-localization-controller.yml.'
intent: 'Validate immutable same-repo localization changes, repair deterministic issues, and request final review.'

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
          persist-credentials: false
      - name: Validate immutable PR head and deterministic checks
        id: prepare
        shell: pwsh
        env:
          PR_NUMBER: ${{ github.event.inputs.pr_number }}
          BASE_SHA: ${{ github.event.inputs.expected_base_sha }}
          HEAD_SHA: ${{ github.event.inputs.expected_head_sha }}
          REPOSITORY: ${{ github.repository }}
          GH_TOKEN: ${{ github.token }}
        run: |
          $ErrorActionPreference = 'Stop'
          . (Join-Path $PWD '.github/skills/ensure-localization/scripts/localization_checks.ps1')
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
          Invoke-GitHubPullRequestHeadFetch -PullRequestNumber $inputs.PrNumber -RemoteRef $remoteRef | Out-Null
          $currentHead = (git rev-parse $remoteRef).Trim().ToLowerInvariant()
          if ($currentHead -ne $inputs.HeadSha) {
            throw "PR head changed after controller dispatch. Expected $($inputs.HeadSha), found $currentHead."
          }

          $alreadyComplete = 'false'
          if ((git log -1 --pretty=%s $inputs.HeadSha) -match '\[localization-expert\]$') {
            $commit = Invoke-GitHubApiJson -Path "repos/$env:REPOSITORY/commits/$($inputs.HeadSha)" -Context 'GitHub commit lookup for localization completion'
            if (Test-LocalizationWorkflowCompletionCommit -Commit $commit -ExpectedHeadSha $inputs.HeadSha) {
              $alreadyComplete = 'true'
            }
          }

          $jsonl = Join-Path $PWD 'ensure-localization.validate.jsonl'
          $previousNativePreference = $PSNativeCommandUseErrorActionPreference
          $PSNativeCommandUseErrorActionPreference = $false
          try {
            & pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $PWD '.github/skills/ensure-localization/scripts/localization_checks.ps1') -Mode Validate -PullRequestNumber $inputs.PrNumber -BaseRevision $inputs.BaseSha -HeadRevision $inputs.HeadSha | Tee-Object -FilePath $jsonl | Out-Null
            $exitCode = $LASTEXITCODE
            $global:LASTEXITCODE = 0
          } finally {
            $PSNativeCommandUseErrorActionPreference = $previousNativePreference
          }
          $completion = Resolve-LocalizationValidatorCompletion -JsonlPath $jsonl -ExitCode $exitCode -AllowedExitCodes @(0, 20, 30, 64)
          $summary = $completion.Summary

          "already_complete=$alreadyComplete" >> $env:GITHUB_OUTPUT
          "comparison_base=$($summary.comparison_base)" >> $env:GITHUB_OUTPUT
          "initial_status=$($summary.status)" >> $env:GITHUB_OUTPUT
          "initial_action=$($summary.action)" >> $env:GITHUB_OUTPUT

  agent:
    needs: [prepare]
    if: needs.prepare.outputs.already_complete != 'true' && needs.prepare.outputs.initial_action != 'ESCALATE'

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
run-name: 'Ensure Localization ${{ github.event.inputs.dispatch_id }}'
---

Same-repo localization repair for PR #${{ github.event.inputs.pr_number }} in `${{ github.event.inputs.repo }}`.

Imported runtime role: `localization-expert`.

Deterministic context:
- trusted base workspace: `${{ github.event.inputs.expected_base_sha }}`
- immutable head: `${{ github.event.inputs.expected_head_sha }}`
- comparison base: `${{ needs.prepare.outputs.comparison_base }}`
- initial validator summary: `${{ needs.prepare.outputs.initial_status }}` /
  `${{ needs.prepare.outputs.initial_action }}`

If you edit localization files in this workspace, rerun deterministic validation
against the current worktree before any commit or push with:

`pwsh .github/skills/ensure-localization/scripts/localization_checks.ps1 -Mode Validate -BaseRevision ${{ github.event.inputs.expected_base_sha }} -ReviewedHeadRevision ${{ github.event.inputs.expected_head_sha }}`

That immutable reviewed head is the source-language authority for repair
validation. Do not change source-language files to make translation checks pass.

## agent: `localization-review-gate`

---
description: 'Performs the independent final localization review for the same-repo workflow'
---

{{#runtime-import .github/agents/localization-reviewer.agent.md}}

## end agent: `localization-review-gate`
