---
description: 'Fork PR localization checker and guidance worker; validates immutable fork localization data from trusted git objects and posts an actionable contributor card only when deterministic fixes are needed. Dispatched by ensure-localization-controller.yml.'
intent: 'Run trusted-base deterministic localization validation against the immutable fork head without checking out fork code, and post one guidance-only comment only when actionable localization fixes are required.'

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
      pull-requests: read
    outputs:
      comparison_base: ${{ steps.prepare.outputs.comparison_base }}
      should_comment: ${{ steps.prepare.outputs.should_comment }}
      comment_body: ${{ steps.prepare.outputs.comment_body }}
    steps:
      - name: Checkout trusted base
        uses: actions/checkout@v7
        with:
          ref: ${{ github.event.inputs.expected_base_sha }}
          fetch-depth: 0
          persist-credentials: false
      - name: Checkout trusted workflow revision
        uses: actions/checkout@v7
        with:
          ref: ${{ github.workflow_sha }}
          path: workflow-helpers
          fetch-depth: 0
          persist-credentials: false
      - name: Validate immutable fork head and prepare actionable guidance
        id: prepare
        shell: pwsh
        env:
          PR_NUMBER: ${{ github.event.inputs.pr_number }}
          BASE_SHA: ${{ github.event.inputs.expected_base_sha }}
          HEAD_SHA: ${{ github.event.inputs.expected_head_sha }}
          REPOSITORY: ${{ github.event.inputs.repo }}
          GITHUB_REPOSITORY: ${{ github.repository }}
          GH_TOKEN: ${{ github.token }}
          GITHUB_SERVER_URL: ${{ github.server_url }}
        run: |
          $ErrorActionPreference = 'Stop'
          $trustedWorkflowRoot = Join-Path $PWD 'workflow-helpers'
          . (Join-Path $trustedWorkflowRoot '.github/skills/ensure-localization/scripts/localization_checks.ps1')

          function Set-GitHubOutputValue {
            param(
              [Parameter(Mandatory)][string]$Name,
              [Parameter(Mandatory)][string]$Value
            )

            $delimiter = "EOF_$([Guid]::NewGuid().ToString('N'))"
            Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$Name<<$delimiter"
            Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value $Value
            Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value $delimiter
          }

          function Write-StepSummary {
            param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)

            Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($Lines -join "`n")
          }

          function Format-FindingMarkdown {
            param([Parameter(Mandatory)][object]$Finding)

            $segments = [System.Collections.Generic.List[string]]::new()
            $segments.Add("- **$($Finding.check_id)**")
            if (-not [string]::IsNullOrWhiteSpace($Finding.file)) {
              $segments.Add("file ``$($Finding.file)``")
            }
            if (-not [string]::IsNullOrWhiteSpace($Finding.resource)) {
              $segments.Add("resource ``$($Finding.resource)``")
            }
            if (-not [string]::IsNullOrWhiteSpace($Finding.message)) {
              $segments.Add($Finding.message)
            }
            if ($null -ne $Finding.observed -and "$($Finding.observed)" -ne '') {
              $segments.Add("Observed: ``$($Finding.observed)``")
            }
            if ($null -ne $Finding.expected -and "$($Finding.expected)" -ne '') {
              $segments.Add("Expected: ``$($Finding.expected)``")
            }
            if (-not [string]::IsNullOrWhiteSpace($Finding.suggested_action)) {
              $segments.Add("Suggested action: $($Finding.suggested_action)")
            }

            return ($segments -join ' — ')
          }

          $inputs = Get-ValidatedWorkflowPrepareInputs -PullRequestNumber $env:PR_NUMBER -BaseRevision $env:BASE_SHA -HeadRevision $env:HEAD_SHA -Repository $env:REPOSITORY -TrustedRepository $env:GITHUB_REPOSITORY
          $serverUrl = $env:GITHUB_SERVER_URL.TrimEnd('/')
          Assert-GitCommitExists -Revision $inputs.BaseRevision

          $remoteRef = "refs/remotes/origin/localization-pr-$($inputs.PullRequestNumber)"
          Invoke-GitHubPullRequestHeadFetch -PullRequestNumber $inputs.PullRequestNumber -RemoteRef $remoteRef | Out-Null
          $currentHead = (git rev-parse $remoteRef).Trim().ToLowerInvariant()
          if ($currentHead -ne $inputs.HeadRevision) {
            throw "Fork PR head changed after controller dispatch. Expected $($inputs.HeadRevision), found $currentHead."
          }
          Assert-GitCommitExists -Revision $inputs.HeadRevision

          $jsonl = Join-Path $PWD 'ensure-localizationguide-forkedrepo.validate.jsonl'
          $previousNativePreference = $PSNativeCommandUseErrorActionPreference
          $PSNativeCommandUseErrorActionPreference = $false
          try {
            & pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $trustedWorkflowRoot '.github/skills/ensure-localization/scripts/localization_checks.ps1') -Mode Validate -PullRequestNumber $inputs.PullRequestNumber -BaseRevision $inputs.BaseRevision -HeadRevision $inputs.HeadRevision | Tee-Object -FilePath $jsonl | Out-Null
            $exitCode = $LASTEXITCODE
            $global:LASTEXITCODE = 0
          } finally {
            $PSNativeCommandUseErrorActionPreference = $previousNativePreference
          }
          $completion = Resolve-LocalizationValidatorCompletion -JsonlPath $jsonl -ExitCode $exitCode -AllowedExitCodes @(0, 20, 30, 64)
          $summary = $completion.Summary
          "comparison_base=$($summary.comparison_base)" >> $env:GITHUB_OUTPUT

          $records = @(Get-Content -LiteralPath $jsonl | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
          $checkRecords = @($records | Where-Object { $_.kind -eq 'check' })

          if ($summary.action -eq 'ESCALATE') {
            $blockedFindings = @($checkRecords | Where-Object { $_.status -eq 'BLOCKED' })
            $summaryLines = [System.Collections.Generic.List[string]]::new()
            $summaryLines.Add('## Localization review')
            $summaryLines.Add('')
            $summaryLines.Add('Fork localization validation blocked before any guidance comment could be posted.')
            $summaryLines.Add('')
            $summaryLines.Add("- Status: **$($summary.status)**")
            $summaryLines.Add("- Action: **$($summary.action)**")
            $summaryLines.Add("- Message: $($summary.message)")
            if ($blockedFindings.Count -gt 0) {
              $summaryLines.Add('')
              $summaryLines.Add('Blocked diagnostics:')
              foreach ($finding in $blockedFindings) {
                $summaryLines.Add((Format-FindingMarkdown -Finding $finding))
              }
            }
            Write-StepSummary -Lines $summaryLines.ToArray()
            throw "Fork localization validation blocked: $($summary.message)"
          }

          if ($summary.action -ne 'FIX') {
            "should_comment=false" >> $env:GITHUB_OUTPUT
            Write-StepSummary -Lines @(
              '## Localization review',
              '',
              'Trusted-base deterministic localization validation found no actionable issues in this fork PR.',
              '',
              "- Status: **$($summary.status)**",
              "- Action: **$($summary.action)**",
              '- PR comment: not posted',
              '- Note: This fork path does not perform independent language-quality review or edit the fork branch.'
            )
            return
          }

          $fixableFindings = @($checkRecords | Where-Object { $_.status -eq 'FIXABLE' })
          if ($fixableFindings.Count -eq 0) {
            throw 'Localization validation requested guidance, but no FIXABLE findings were available to cite.'
          }

          $pathKinds = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
          $relevantPathSet = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
          foreach ($finding in $fixableFindings) {
            if ([string]::IsNullOrWhiteSpace($finding.file)) {
              throw "Localization guidance requires every FIXABLE finding to include a supported file path. Missing file for check '$($finding.check_id)'."
            }

            $kind = Get-LocalizationFileKind -Path $finding.file
            if ($null -eq $kind) {
              throw "Localization guidance does not support validator finding path '$($finding.file)'."
            }

            $null = $pathKinds.Add($kind)
            $null = $relevantPathSet.Add($finding.file)
          }
          $relevantPaths = @($relevantPathSet)
          if ($relevantPaths.Count -eq 0) {
            throw 'Localization guidance requires at least one validator-reported localization file path.'
          }

          $referenceItems = [System.Collections.Generic.List[hashtable]]::new()
          $skillPath = '.github/skills/ensure-localization/SKILL.md'
          $referenceItems.Add(@{
            Path = $skillPath
            Url = "$serverUrl/$($inputs.Repository)/blob/$($inputs.BaseRevision)/.github/skills/ensure-localization/SKILL.md"
          })
          if ($pathKinds.Contains('resw')) {
            $referenceItems.Add(@{
              Path = '.github/instructions/localization.instructions.md'
              Url = "$serverUrl/$($inputs.Repository)/blob/$($inputs.BaseRevision)/.github/instructions/localization.instructions.md"
            })
          }
          if ($pathKinds.Contains('wta')) {
            $referenceItems.Add(@{
              Path = '.github/instructions/rust-localization.instructions.md'
              Url = "$serverUrl/$($inputs.Repository)/blob/$($inputs.BaseRevision)/.github/instructions/rust-localization.instructions.md"
            })
          }
          if ($referenceItems.Count -le 1) {
            throw 'Localization findings did not map to a supported localization instruction file.'
          }

          $referenceLinks = @(
            $referenceItems | ForEach-Object { "- [``$($_.Path)``]($($_.Url))" }
          ) -join "`n"
          $referencePromptLines = @(
            $referenceItems | ForEach-Object { "- $($_.Path)" }
          ) -join "`n"

          $typeLines = [System.Collections.Generic.List[string]]::new()
          if ($pathKinds.Contains('resw')) {
            $typeLines.Add('- `.resw` resource files')
          }
          if ($pathKinds.Contains('wta')) {
            $typeLines.Add('- `tools/wta/locales/*.yml` locale files')
          }
          $changedTypeLines = if ($typeLines.Count -gt 0) { $typeLines.ToArray() -join "`n" } else { '- localized files reported by the validator' }
          $codeFence = '```'

          $findingLines = @(
            $fixableFindings |
              Select-Object -First 12 |
              ForEach-Object { Format-FindingMarkdown -Finding $_ }
          ) -join "`n"

          $missingFilesNote = 'If your local clone does not yet contain one of the linked files, open it from the trusted base repository links above and include it in Copilot context.'

          $promptLines = [System.Collections.Generic.List[string]]::new()
          $promptLines.Add('Fix only the customer-facing localization issues reported below in this pull request.')
          $promptLines.Add('')
          $promptLines.Add("Repository: $($inputs.Repository)")
          $promptLines.Add("Pull request: #$($inputs.PullRequestNumber)")
          $promptLines.Add("Head SHA: $($inputs.HeadRevision)")
          $promptLines.Add("Comparison base: $($summary.comparison_base)")
          $promptLines.Add('')
          $promptLines.Add('Follow these trusted repository localization references:')
          foreach ($line in @($referencePromptLines -split "`r?`n" | Where-Object { $_ })) {
            $promptLines.Add($line)
          }
          $promptLines.Add('')
          $promptLines.Add('Validator-reported localization file types:')
          foreach ($line in @($changedTypeLines -split "`r?`n" | Where-Object { $_ })) {
            $promptLines.Add($line)
          }
          $promptLines.Add('')
          $promptLines.Add('Deterministic findings to fix:')
          foreach ($line in @($findingLines -split "`r?`n" | Where-Object { $_ })) {
            $promptLines.Add($line)
          }
          $promptLines.Add('')
          $promptLines.Add('Use the shared localization skill for the repair procedure. Use the wrapper references above only to confirm the applicable file types. Do normal diff inspection yourself, fix only the validator-reported entries, preserve placeholders, locks, comments, BOM, structure, ordering, and pseudo-locale style, and do not change unrelated files or en-US source unless the PR intentionally changed source text. Before commit or push, rerun `pwsh .github/skills/ensure-localization/scripts/localization_checks.ps1 -Mode Validate -BaseRevision <base-sha> -ReviewedHeadRevision <head-sha>` and finish with an independent read-only review.')
          $promptBody = ($promptLines.ToArray() -join "`n")

          $cardLines = [System.Collections.Generic.List[string]]::new()
          $cardLines.Add('## Localization action required')
          $cardLines.Add('')
          $cardLines.Add('Trusted-base deterministic localization checks found actionable issues in this fork PR.')
          $cardLines.Add('')
          $cardLines.Add('Automatic same-repo localization repair is unavailable for fork PRs under the current repository token.')
          $cardLines.Add('')
          $cardLines.Add('Guidance only — this workflow validated immutable localization data but did not change the fork branch or perform independent language-quality review.')
          $cardLines.Add('')
          $cardLines.Add('Actionable findings:')
          foreach ($line in @($findingLines -split "`r?`n" | Where-Object { $_ })) {
            $cardLines.Add($line)
          }
          $cardLines.Add('')
          $cardLines.Add('Applicable repository localization references for this PR (trusted base):')
          foreach ($line in @($referenceLinks -split "`r?`n" | Where-Object { $_ })) {
            $cardLines.Add($line)
          }
          $cardLines.Add('')
          $cardLines.Add('Validator-reported localization file types:')
          foreach ($line in @($changedTypeLines -split "`r?`n" | Where-Object { $_ })) {
            $cardLines.Add($line)
          }
          $cardLines.Add('')
          $cardLines.Add('1. Check out this PR branch locally.')
          $cardLines.Add('2. Open Copilot in that local checkout.')
          $cardLines.Add('3. Paste the prompt below.')
          $cardLines.Add('4. Follow the skill''s repair flow, run the validator and independent review it defines, then commit and push the updates back to this PR branch.')
          $cardLines.Add('')
          $cardLines.Add($missingFilesNote)
          $cardLines.Add('')
          $cardLines.Add("$($codeFence)text")
          foreach ($line in @($promptBody -split "`r?`n")) {
            $cardLines.Add($line)
          }
          $cardLines.Add($codeFence)
          $cardBody = ($cardLines.ToArray() -join "`n")

          "should_comment=true" >> $env:GITHUB_OUTPUT
          Set-GitHubOutputValue -Name 'comment_body' -Value $cardBody
          Write-StepSummary -Lines @(
            '## Localization review',
            '',
            'Trusted-base deterministic localization validation found actionable fork issues. A guidance comment will be posted.',
            '',
            "- Findings: **$($fixableFindings.Count)**",
            "- Comparison base: ``$($summary.comparison_base)``"
          )

  agent:
    needs: [prepare]
    if: needs.prepare.outputs.should_comment == 'true'

safe-outputs:
  add-comment:
    target: '*'
    max: 1
    hide-older-comments: true

timeout-minutes: 15
max-ai-credits: 150
max-daily-ai-credits: 750
concurrency:
  group: 'localization-guide-fork-${{ github.event.inputs.pr_number }}'
  job-discriminator: ${{ github.run_id }}
  cancel-in-progress: true
run-name: 'Ensure Localization Guide Forked Repo ${{ github.event.inputs.dispatch_id }}'
---

Fork localization guidance for PR #${{ github.event.inputs.pr_number }} in `${{ github.event.inputs.repo }}`.

The prepare job already ran deterministic localization validation against the
immutable fork head with trusted git objects only. It prepared a Markdown card
only because actionable FIXABLE findings were detected.

Post exactly one comment via `add-comment` using this prepared body. Do not
claim that localization is fully validated or repaired, and do not add any
other visible output:

${{ needs.prepare.outputs.comment_body }}
