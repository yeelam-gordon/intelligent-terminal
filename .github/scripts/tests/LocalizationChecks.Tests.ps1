#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

# Unit tests for .github/scripts/localization_checks.ps1.
# Fixture purposes:
# - exit64-summary.jsonl: JSONL summary contract for the exit-64 path, including last-line parsing.
# - commit-null-author.json / commit-null-committer.json: missing GitHub commit metadata must fail closed.
# - commit-valid-bot-verified-single-parent.json: verified completion commit happy path.

Describe 'Localization checker unit tests' -Tag 'Unit' {
    BeforeEach {
        $script:ResultRecords = [System.Collections.Generic.List[object]]::new()
    }

    BeforeAll {
        $script:checkerScript = Join-Path $PSScriptRoot '..\localization_checks.ps1'
        $script:fixtureRoot = Join-Path $PSScriptRoot 'fixtures\localization-validator'

        foreach ($name in @(
            'Mode'
            'PullRequestNumber'
            'BaseRevision'
            'HeadRevision'
            'RepositoryRoot'
            'LocalizationPathspecs'
            'ExitCodes'
            'ResultRecords'
            'FileBytesCache'
            'ParsedReswCache'
            'ParsedWtaCache'
            'RepositoryRootPath'
        )) {
            Remove-Variable -Scope Script -Name $name -ErrorAction SilentlyContinue
        }

        . $script:checkerScript

        function Get-LocalizationValidatorCommitFixture {
            param([Parameter(Mandatory)][string]$Name)

            $fixturePath = Join-Path $script:fixtureRoot $Name
            Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json -AsHashtable
        }

        function New-LocalizationValidatorJsonl {
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][string]$Status,
                [Parameter(Mandatory)][string]$Action,
                [Parameter(Mandatory)][bool]$ShouldRun,
                [string]$Mode = 'Validate',
                [string]$Message = 'fixture summary',
                [int]$TotalCount = 1,
                [int]$PassCount = 1,
                [int]$FixableCount = 0,
                [int]$BlockedCount = 0
            )

            $records = @(
                [ordered]@{
                    kind = 'check'
                    mode = $Mode
                    status = 'PASS'
                    action = 'NONE'
                    should_run = $null
                    check_id = 'input.validation'
                    file = $null
                    resource = $null
                    observed = $null
                    expected = $null
                    message = 'fixture check'
                    suggested_action = $null
                    comparison_base = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
                    total_count = $null
                    pass_count = $null
                    fixable_count = $null
                    blocked_count = $null
                }
                [ordered]@{
                    kind = 'summary'
                    mode = $Mode
                    status = $Status
                    action = $Action
                    should_run = $ShouldRun
                    check_id = 'input.validation'
                    file = $null
                    resource = $null
                    observed = $null
                    expected = $null
                    message = $Message
                    suggested_action = $null
                    comparison_base = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
                    total_count = $TotalCount
                    pass_count = $PassCount
                    fixable_count = $FixableCount
                    blocked_count = $BlockedCount
                }
            )

            $records | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 } | Set-Content -LiteralPath $Path -Encoding utf8
        }

        function Get-LocalizationValidatorFixtureBytes {
            param([Parameter(Mandatory)][string]$Name)

            $fixturePath = Join-Path $script:fixtureRoot $Name
            [System.IO.File]::ReadAllBytes($fixturePath)
        }
    }
    Describe 'Localization validator completion contract' {
    It 'reads the final JSONL summary line and suppresses follow-up work for exit 64' {
        $jsonlPath = Join-Path $TestDrive 'exit64-summary.jsonl'
        Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'exit64-summary.jsonl') -Destination $jsonlPath

        $completion = Resolve-LocalizationValidatorCompletion -JsonlPath $jsonlPath -ExitCode 64

        $completion.Summary.kind | Should -Be 'summary'
        $completion.Summary.status | Should -Be 'BLOCKED'
        $completion.Summary.action | Should -Be 'ESCALATE'
        $completion.ShouldRun | Should -BeFalse
    }

    It 'accepts the supported native exit codes with the matching summary contract' -TestCases @(
        @{ ExitCode = 0; SummaryStatus = 'PASS'; SummaryAction = 'NONE'; SummaryShouldRun = $false; ExpectedShouldRun = $false }
        @{ ExitCode = 10; SummaryStatus = 'PASS'; SummaryAction = 'REVIEW'; SummaryShouldRun = $true; ExpectedShouldRun = $true }
        @{ ExitCode = 20; SummaryStatus = 'FIXABLE'; SummaryAction = 'FIX'; SummaryShouldRun = $true; ExpectedShouldRun = $true }
        @{ ExitCode = 30; SummaryStatus = 'BLOCKED'; SummaryAction = 'ESCALATE'; SummaryShouldRun = $true; ExpectedShouldRun = $false }
    ) {
        param(
            [int]$ExitCode,
            [string]$SummaryStatus,
            [string]$SummaryAction,
            [bool]$SummaryShouldRun,
            [bool]$ExpectedShouldRun
        )

        $jsonlPath = Join-Path $TestDrive ("summary-{0}.jsonl" -f $ExitCode)
        New-LocalizationValidatorJsonl -Path $jsonlPath -Status $SummaryStatus -Action $SummaryAction -ShouldRun $SummaryShouldRun

        $completion = Resolve-LocalizationValidatorCompletion -JsonlPath $jsonlPath -ExitCode $ExitCode

        $completion.Summary.status | Should -Be $SummaryStatus
        $completion.Summary.action | Should -Be $SummaryAction
        $completion.ShouldRun | Should -Be $ExpectedShouldRun
    }
    It 'rejects unsupported native exit codes before trusting the JSONL payload' {
        $jsonlPath = Join-Path $TestDrive 'unexpected-exit.jsonl'
        New-LocalizationValidatorJsonl -Path $jsonlPath -Status 'PASS' -Action 'NONE' -ShouldRun $false

        { Resolve-LocalizationValidatorCompletion -JsonlPath $jsonlPath -ExitCode 99 } |
            Should -Throw '*Unexpected localization validator exit code: 99*'
    }
    It 'rejects exit 64 when the summary is not BLOCKED/ESCALATE' {
        $jsonlPath = Join-Path $TestDrive 'invalid-exit64.jsonl'
        New-LocalizationValidatorJsonl -Path $jsonlPath -Status 'PASS' -Action 'REVIEW' -ShouldRun $true

        { Resolve-LocalizationValidatorCompletion -JsonlPath $jsonlPath -ExitCode 64 } |
            Should -Throw '*exit 64 must emit a BLOCKED/ESCALATE summary record*'
    }
    }
    Describe 'GitHub API JSON capture' {
        It 'fails closed on a nonzero exit before using the payload' {
            { Resolve-GitHubApiJson -Context 'GitHub commit lookup' -ExitCode 1 -Stdout '{"login":"github-actions[bot]"}' } |
                Should -Throw '*GitHub commit lookup failed with exit code 1.*'
        }
        It 'fails closed when gh returns no JSON output' {
            { Resolve-GitHubApiJson -Context 'GitHub commit lookup' -ExitCode 0 -Stdout '' } |
                Should -Throw '*GitHub commit lookup returned no JSON output.*'
        }
        It 'fails closed when gh returns invalid JSON' {
            { Resolve-GitHubApiJson -Context 'GitHub commit lookup' -ExitCode 0 -Stdout '{not json}' } |
                Should -Throw '*GitHub commit lookup returned invalid JSON output.*'
        }
        It 'returns parsed JSON for a valid payload' {
            $result = Resolve-GitHubApiJson -Context 'GitHub commit lookup' -ExitCode 0 -Stdout '{"login":"github-actions[bot]","id":1,"verified":true}'

            $result.login | Should -Be 'github-actions[bot]'
            $result.id | Should -Be 1
            $result.verified | Should -BeTrue
        }
    }
    Describe 'Process byte capture' {
        It 'drains stdout bytes and stderr concurrently without deadlocking and preserves raw stdout bytes' {
            $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
            $scriptPath = Join-Path $TestDrive 'mixed-streams.ps1'
            @'
$chunk = [byte[]](0..255)
$stdout = [Console]::OpenStandardOutput()
for ($i = 0; $i -lt 256; $i++) {
    $stdout.Write($chunk, 0, $chunk.Length)
    [Console]::Error.WriteLine(('stderr-block-{0}:{1}' -f $i, ('x' * 4096)))
}
$stdout.Flush()
'@ | Set-Content -LiteralPath $scriptPath -Encoding utf8

            $result = Invoke-ProcessBytes -FilePath $pwsh -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $scriptPath) -TimeoutMilliseconds 10000

            $result.ExitCode | Should -Be 0
            $result.Bytes.Length | Should -Be (256 * 256)
            $result.Bytes[0] | Should -Be 0
            $result.Bytes[255] | Should -Be 255
            $result.Bytes[256] | Should -Be 0
            $result.Stderr | Should -Match 'stderr-block-255'
        }

        It 'returns nonzero exit codes and stderr without throwing' {
            $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
            $scriptPath = Join-Path $TestDrive 'nonzero.ps1'
            @'
[Console]::Error.WriteLine('boom')
exit 23
'@ | Set-Content -LiteralPath $scriptPath -Encoding utf8

            $result = Invoke-ProcessBytes -FilePath $pwsh -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $scriptPath)

            $result.ExitCode | Should -Be 23
            $result.Stderr | Should -Be 'boom'
        }

        It 'times out and terminates the owned process tree' {
            $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
            $scriptPath = Join-Path $TestDrive 'timeout.ps1'
            $pidPath = Join-Path $TestDrive 'timeout.pid'
            @'
param([string]$PidPath)
[System.IO.File]::WriteAllText($PidPath, [string]$PID)
Start-Sleep -Seconds 30
'@ | Set-Content -LiteralPath $scriptPath -Encoding utf8

            { Invoke-ProcessBytes -FilePath $pwsh -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $scriptPath, $pidPath) -TimeoutMilliseconds 500 } |
                Should -Throw '*timed out after 500 ms*'

            $processId = $null
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            while ([DateTime]::UtcNow -lt $deadline) {
                if (Test-Path -LiteralPath $pidPath) {
                    $processId = [int](Get-Content -LiteralPath $pidPath -Raw)
                    break
                }

                Start-Sleep -Milliseconds 100
            }

            $processId | Should -Not -BeNullOrEmpty

            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            do {
                $runningProcess = Get-Process -Id $processId -ErrorAction SilentlyContinue
                if ($null -eq $runningProcess) {
                    break
                }

                Start-Sleep -Milliseconds 100
            } while ([DateTime]::UtcNow -lt $deadline)

            (Get-Process -Id $processId -ErrorAction SilentlyContinue) | Should -Be $null
        }
    }
    Describe 'Trusted repository and pull request file paging' {
        It 'requires the requested repository to match the trusted repository' {
            { Resolve-TrustedGitHubRepository -Repository 'octocat/hello-world' -TrustedRepository 'microsoft/intelligent-terminal' } |
                Should -Throw "*does not match trusted repository 'microsoft/intelligent-terminal'*"
        }

        It 'returns the trusted repository when the input matches case-insensitively' {
            Resolve-TrustedGitHubRepository -Repository 'Microsoft/Intelligent-Terminal' -TrustedRepository 'microsoft/intelligent-terminal' |
                Should -Be 'microsoft/intelligent-terminal'
        }

        It 'pages exactly to the reported changed_files count and stops there' {
            $apiPaths = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-GitHubApiJson {
                param([string]$Path, [string]$Context)

                $apiPaths.Add($Path) | Out-Null
                if ($Path -eq 'repos/microsoft/intelligent-terminal/pulls/17') {
                    return @{ changed_files = 201 }
                }

                if ($Path -eq 'repos/microsoft/intelligent-terminal/pulls/17/files?per_page=100&page=1') {
                    return @(1..100 | ForEach-Object { @{ filename = "file-$_.txt" } })
                }

                if ($Path -eq 'repos/microsoft/intelligent-terminal/pulls/17/files?per_page=100&page=2') {
                    return @(101..200 | ForEach-Object { @{ filename = "file-$_.txt" } })
                }

                if ($Path -eq 'repos/microsoft/intelligent-terminal/pulls/17/files?per_page=100&page=3') {
                    return @(@{ filename = 'file-201.txt' })
                }

                throw "Unexpected API path: $Path"
            }

            $files = Get-GitHubPullRequestFiles -Repository 'microsoft/intelligent-terminal' -PullRequestNumber '17'

            $files.Count | Should -Be 201
            $apiPaths | Should -HaveCount 4
            $apiPaths[-1] | Should -Be 'repos/microsoft/intelligent-terminal/pulls/17/files?per_page=100&page=3'
        }

        It 'blocks when pull request metadata exceeds the documented file limit' {
            Mock Invoke-GitHubApiJson {
                param([string]$Path, [string]$Context)

                if ($Path -eq 'repos/microsoft/intelligent-terminal/pulls/18') {
                    return @{ changed_files = 3001 }
                }

                throw "Unexpected API path: $Path"
            }

            { Get-GitHubPullRequestFiles -Repository 'microsoft/intelligent-terminal' -PullRequestNumber '18' } |
                Should -Throw '*exceeding the documented 3000-file API limit*'
        }

        It 'blocks when the paged file listing returns fewer files than changed_files' {
            Mock Invoke-GitHubApiJson {
                param([string]$Path, [string]$Context)

                if ($Path -eq 'repos/microsoft/intelligent-terminal/pulls/19') {
                    return @{ changed_files = 250 }
                }

                if ($Path -eq 'repos/microsoft/intelligent-terminal/pulls/19/files?per_page=100&page=1') {
                    return @(1..100 | ForEach-Object { @{ filename = "file-$_.txt" } })
                }

                if ($Path -eq 'repos/microsoft/intelligent-terminal/pulls/19/files?per_page=100&page=2') {
                    return @(101..200 | ForEach-Object { @{ filename = "file-$_.txt" } })
                }

                if ($Path -eq 'repos/microsoft/intelligent-terminal/pulls/19/files?per_page=100&page=3') {
                    return @()
                }

                throw "Unexpected API path: $Path"
            }

            { Get-GitHubPullRequestFiles -Repository 'microsoft/intelligent-terminal' -PullRequestNumber '19' } |
                Should -Throw '*stopped after 200 of 250 files*'
        }
    }
    Describe 'Localization checker provenance' {
    It 'treats a null author as not-completion' {
        $commit = Get-LocalizationValidatorCommitFixture -Name 'commit-null-author.json'

        Test-LocalizationWorkflowCompletionCommit -Commit $commit -ExpectedHeadSha '0123456789012345678901234567890123456789' |
            Should -BeFalse
    }

    It 'treats a null committer as not-completion' {
        $commit = Get-LocalizationValidatorCommitFixture -Name 'commit-null-committer.json'

        Test-LocalizationWorkflowCompletionCommit -Commit $commit -ExpectedHeadSha '0123456789012345678901234567890123456789' |
            Should -BeFalse
    }

    It 'accepts the verified bot single-parent completion commit' {
        $commit = Get-LocalizationValidatorCommitFixture -Name 'commit-valid-bot-verified-single-parent.json'

        Test-LocalizationWorkflowCompletionCommit -Commit $commit -ExpectedHeadSha 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' |
            Should -BeTrue
    }
    }

    Describe 'WTA locked token validation' {
        BeforeAll {
            $fixtureBytes = Get-LocalizationValidatorFixtureBytes -Name 'wta-clean-c-locked-source.yml'
            $script:wtaLockedSourceFixture = Read-WtaLocaleEntries -Bytes $fixtureBytes -Path 'tools/wta/locales/en-US.yml'
        }

        It 'does not invent file-level locked tokens for a fully locked source value that lacks them' {
            $sourceEntry = $script:wtaLockedSourceFixture.Entries['demo.clean_c.visible_review']
            $rules = Get-LockedRules -Comments (Get-WtaEntryComments -Entry $sourceEntry) -Locale 'qps-ploc'

            Test-LockedToken -CheckId 'validate.wta.locked-token' -File 'tools/wta/locales/qps-ploc.yml' `
                -Resource $sourceEntry.Key -Locale 'qps-ploc' -SourceValue $sourceEntry.Value -TargetValue $sourceEntry.Value `
                -Rules $rules -ComparisonBase '533f42bbae811f03fdb58957803259213dea143c'

            @($script:ResultRecords).Count | Should -Be 0
        }

        It 'reports a missing locale-scoped token when the source value contains it literally' {
            $sourceEntry = $script:wtaLockedSourceFixture.Entries['demo.clean_c.visible_review_with_product']
            $rules = Get-LockedRules -Comments (Get-WtaEntryComments -Entry $sourceEntry) -Locale 'qps-ploc'

            Test-LockedToken -CheckId 'validate.wta.locked-token' -File 'tools/wta/locales/qps-ploc.yml' `
                -Resource $sourceEntry.Key -Locale 'qps-ploc' -SourceValue $sourceEntry.Value -TargetValue 'GHAW Visible Review' `
                -Rules $rules -ComparisonBase '533f42bbae811f03fdb58957803259213dea143c'

            $script:ResultRecords | Should -HaveCount 1
            $script:ResultRecords[0].status | Should -Be 'FIXABLE'
            $script:ResultRecords[0].expected | Should -Be 'Intelligent Terminal'
            $script:ResultRecords[0].message | Should -Match "Locked token 'Intelligent Terminal' is missing"
        }

        It 'requires full-lock equality instead of suggesting phrase insertion' {
            $sourceEntry = $script:wtaLockedSourceFixture.Entries['demo.clean_c.visible_review']
            $rules = Get-LockedRules -Comments (Get-WtaEntryComments -Entry $sourceEntry) -Locale 'qps-ploc'

            Test-LockedToken -CheckId 'validate.wta.locked-token' -File 'tools/wta/locales/qps-ploc.yml' `
                -Resource $sourceEntry.Key -Locale 'qps-ploc' -SourceValue $sourceEntry.Value `
                -TargetValue 'GHAW Visible Review — Intelligent Terminal' -Rules $rules `
                -ComparisonBase '533f42bbae811f03fdb58957803259213dea143c'

            $script:ResultRecords | Should -HaveCount 1
            $script:ResultRecords[0].expected | Should -Be 'GHAW Visible Review'
            $script:ResultRecords[0].message | Should -Be 'This value is fully locked and must remain identical to the source.'
        }

        It 'applies locale-scoped locked tokens only to the matching locales' {
            $sourceEntry = $script:wtaLockedSourceFixture.Entries['demo.clean_c.visible_review_with_product']
            $rules = Get-LockedRules -Comments (Get-WtaEntryComments -Entry $sourceEntry) -Locale 'lv-LV'

            Test-LockedToken -CheckId 'validate.wta.locked-token' -File 'tools/wta/locales/lv-LV.yml' `
                -Resource $sourceEntry.Key -Locale 'lv-LV' -SourceValue $sourceEntry.Value -TargetValue 'GHAW Visible Review' `
                -Rules $rules -ComparisonBase '533f42bbae811f03fdb58957803259213dea143c'

            @($script:ResultRecords).Count | Should -Be 0
        }
    }
}
