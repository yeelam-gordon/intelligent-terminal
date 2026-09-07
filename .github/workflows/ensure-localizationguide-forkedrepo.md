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
            $trustedRepository = Resolve-TrustedGitHubRepository -Repository $env:REPOSITORY -TrustedRepository $env:GITHUB_REPOSITORY

            return @{
              PrNumber = $env:PR_NUMBER
              BaseSha = $env:BASE_SHA.ToLowerInvariant()
              HeadSha = $env:HEAD_SHA.ToLowerInvariant()
              Repository = $trustedRepository
              ServerUrl = $env:GITHUB_SERVER_URL.TrimEnd('/')
            }
          }

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
            param([Parameter(Mandatory)][string[]]$Lines)

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

          $inputs = Get-ValidatedPrepareInputs
          Assert-GitCommitExists -Revision $inputs.BaseSha

          $remoteRef = "refs/remotes/origin/localization-pr-$($inputs.PrNumber)"
          Invoke-GitHubPullRequestHeadFetch -PullRequestNumber $inputs.PrNumber -RemoteRef $remoteRef | Out-Null
          $currentHead = (git rev-parse $remoteRef).Trim().ToLowerInvariant()
          if ($currentHead -ne $inputs.HeadSha) {
            throw "Fork PR head changed after controller dispatch. Expected $($inputs.HeadSha), found $currentHead."
          }
          Assert-GitCommitExists -Revision $inputs.HeadSha

          $jsonl = Join-Path $PWD 'ensure-localizationguide-forkedrepo.validate.jsonl'
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

          $files = @(Get-GitHubPullRequestFiles -Repository $inputs.Repository -PullRequestNumber $inputs.PrNumber)
          $filePaths = @(
            $files |
              ForEach-Object { $_.filename } |
              Sort-Object -Unique
          )
          $reswPaths = @(
            $filePaths |
              Where-Object { $_ -match '^src/cascadia/.+/Resources(?:/[^/]+)*/[^/]+\.resw$' } |
              Sort-Object -Unique
          )
          $wtaPaths = @(
            $filePaths |
              Where-Object { $_ -match '^tools/wta/locales/[^/]+\.yml$' } |
              Sort-Object -Unique
          )

          $findingPaths = @(
            $fixableFindings |
              ForEach-Object { $_.file } |
              Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
              Sort-Object -Unique
          )
          $relevantPaths = if ($findingPaths.Count -gt 0) { $findingPaths } else { @($reswPaths + $wtaPaths | Sort-Object -Unique) }

          $referenceItems = [System.Collections.Generic.List[hashtable]]::new()
          $skillPath = '.github/skills/ensure-localization/SKILL.md'
          $referenceItems.Add(@{
            Path = $skillPath
            Url = "$($inputs.ServerUrl)/$($inputs.Repository)/blob/$($inputs.BaseSha)/.github/skills/ensure-localization/SKILL.md"
          })
          if (@($relevantPaths | Where-Object { $_ -match '\.resw$' }).Count -gt 0) {
            $referenceItems.Add(@{
              Path = '.github/instructions/localization.instructions.md'
              Url = "$($inputs.ServerUrl)/$($inputs.Repository)/blob/$($inputs.BaseSha)/.github/instructions/localization.instructions.md"
            })
          }
          if (@($relevantPaths | Where-Object { $_ -match '^tools/wta/locales/[^/]+\.yml$' }).Count -gt 0) {
            $referenceItems.Add(@{
              Path = '.github/instructions/rust-localization.instructions.md'
              Url = "$($inputs.ServerUrl)/$($inputs.Repository)/blob/$($inputs.BaseSha)/.github/instructions/rust-localization.instructions.md"
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
          if ($reswPaths.Count -gt 0) {
            $typeLines.Add('- `.resw` resource files')
          }
          if ($wtaPaths.Count -gt 0) {
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
          $promptLines.Add("Pull request: #$($inputs.PrNumber)")
          $promptLines.Add("Head SHA: $($inputs.HeadSha)")
          $promptLines.Add("Comparison base: $($summary.comparison_base)")
          $promptLines.Add('')
          $promptLines.Add('Follow these trusted repository localization references:')
          foreach ($line in @($referencePromptLines -split "`r?`n" | Where-Object { $_ })) {
            $promptLines.Add($line)
          }
          $promptLines.Add('')
          $promptLines.Add('Changed localization file types in this PR:')
          foreach ($line in @($changedTypeLines -split "`r?`n" | Where-Object { $_ })) {
            $promptLines.Add($line)
          }
          $promptLines.Add('')
          $promptLines.Add('Deterministic findings to fix:')
          foreach ($line in @($findingLines -split "`r?`n" | Where-Object { $_ })) {
            $promptLines.Add($line)
          }
          $promptLines.Add('')
          $promptLines.Add('Use the localization skill as the workflow authority. Use the wrapper file or files above only to confirm which file-type scope applies. Update every required locale already shipped for the affected component(s), preserve placeholders, locked values and locked tokens, translator comments, BOM and encoding, XML or YAML structure, required ordering, and pseudo-locale style, and do not change unrelated files or source-language en-US strings unless the PR explicitly changes source text. Follow the skill''s validate → repair → validate → independent review flow before committing and pushing the localization-only updates for this PR branch.')
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
          $cardLines.Add('Detected localization file types:')
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
max-turns: 12
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
