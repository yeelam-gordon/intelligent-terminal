#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

# Unit tests for .github/skills/ensure-localization/scripts/localization_checks.ps1.
# Fixtures are defined inline or in TestDrive to keep the skill self-contained.

Describe 'Localization checker unit tests' -Tag 'Unit' {
    BeforeEach {
        $script:ResultRecords = [System.Collections.Generic.List[object]]::new()
    }

    BeforeAll {
        $script:checkerScript = Join-Path $PSScriptRoot '..\scripts\localization_checks.ps1'

        foreach ($name in @(
            'Mode'
            'PullRequestNumber'
            'BaseRevision'
            'HeadRevision'
            'ReviewedHeadRevision'
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

        function New-LocalizationValidatorCommit {
            param(
                [AllowNull()][string]$AuthorLogin = 'github-actions[bot]',
                [AllowNull()][string]$CommitterLogin = 'web-flow',
                [bool]$Verified = $true,
                [string]$ParentSha = '0123456789012345678901234567890123456789'
            )

            return @{
                author = if ($null -eq $AuthorLogin) { $null } else { @{ login = $AuthorLogin } }
                committer = if ($null -eq $CommitterLogin) { $null } else { @{ login = $CommitterLogin } }
                commit = @{
                    verification = @{
                        verified = $Verified
                    }
                }
                parents = @(
                    @{
                        sha = $ParentSha
                    }
                )
            }
        }

        function New-Utf8Bytes {
            param([Parameter(Mandatory)][string]$Text)

            return ([System.Text.UTF8Encoding]::new($false)).GetBytes($Text)
        }

        function Write-Utf8TextFile {
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][string]$Content,
                [bool]$WithBom = $false
            )

            $directory = Split-Path -Path $Path -Parent
            if (-not [string]::IsNullOrWhiteSpace($directory)) {
                [System.IO.Directory]::CreateDirectory($directory) | Out-Null
            }

            $encoding = [System.Text.UTF8Encoding]::new($false)
            $bytes = $encoding.GetBytes($Content)
            if ($WithBom) {
                $bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + $bytes)
            }

            [System.IO.File]::WriteAllBytes($Path, $bytes)
        }

        function Write-ReswFixtureFile {
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][object[]]$Resources
            )

            $builder = [System.Text.StringBuilder]::new()
            [void]$builder.AppendLine('<?xml version="1.0" encoding="utf-8"?>')
            [void]$builder.AppendLine('<root>')
            foreach ($resource in $Resources) {
                $name = [System.Security.SecurityElement]::Escape([string]$resource.Name)
                $value = [System.Security.SecurityElement]::Escape([string]$resource.Value)
                [void]$builder.AppendLine("  <data name=""$name"" xml:space=""preserve"">")
                [void]$builder.AppendLine("    <value>$value</value>")
                if ($resource.ContainsKey('Comment') -and $null -ne $resource.Comment) {
                    $comment = [System.Security.SecurityElement]::Escape([string]$resource.Comment)
                    [void]$builder.AppendLine("    <comment>$comment</comment>")
                }
                [void]$builder.AppendLine('  </data>')
            }
            [void]$builder.AppendLine('</root>')

            Write-Utf8TextFile -Path $Path -Content $builder.ToString() -WithBom $true
        }

        function Write-WtaFixtureFile {
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][object[]]$Entries
            )

            $lines = [System.Collections.Generic.List[string]]::new()
            foreach ($entry in $Entries) {
                $value = ConvertTo-Json -InputObject ([string]$entry.Value) -Compress
                $lines.Add(('{0}: {1}' -f $entry.Name, $value))
            }

            Write-Utf8TextFile -Path $Path -Content ($lines -join "`n") -WithBom $false
        }

        function Invoke-TestGit {
            param(
                [Parameter(Mandatory)][string]$RepositoryPath,
                [Parameter(Mandatory)][string[]]$Arguments
            )

            $output = & git -C $RepositoryPath @Arguments 2>&1
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                throw "git $($Arguments -join ' ') failed with exit code $exitCode. $(@($output) -join "`n")"
            }

            return (@($output) -join "`n").Trim()
        }

        function New-ReviewedSourceScenario {
            param(
                [Parameter(Mandatory)][ValidateSet('resw', 'wta')][string]$Kind,
                [Parameter(Mandatory)][ValidateSet('deleted-source', 'edited-source', 'missing-locale', 'translated-targets', 'reviewed-source-change-accepted')][string]$Scenario
            )

            $repoPath = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
            [System.IO.Directory]::CreateDirectory($repoPath) | Out-Null

            Invoke-TestGit -RepositoryPath $repoPath -Arguments @('init') | Out-Null
            Invoke-TestGit -RepositoryPath $repoPath -Arguments @('config', 'user.name', 'Test User') | Out-Null
            Invoke-TestGit -RepositoryPath $repoPath -Arguments @('config', 'user.email', 'test@example.com') | Out-Null

            if ($Kind -eq 'resw') {
                $sourcePath = Join-Path $repoPath 'src\cascadia\Demo\Resources\en-US\Strings.resw'
                $localePath = Join-Path $repoPath 'src\cascadia\Demo\Resources\fr-FR\Strings.resw'
                $writeSource = {
                    param([object[]]$Entries)
                    Write-ReswFixtureFile -Path $sourcePath -Resources $Entries
                }
                $writeLocale = {
                    param([object[]]$Entries)
                    Write-ReswFixtureFile -Path $localePath -Resources $Entries
                }
            } else {
                $sourcePath = Join-Path $repoPath 'tools\wta\locales\en-US.yml'
                $localePath = Join-Path $repoPath 'tools\wta\locales\fr-FR.yml'
                Write-ReswFixtureFile -Path (Join-Path $repoPath 'src\cascadia\TerminalApp\Resources\en-US\Resources.resw') -Resources @(
                    @{ Name = 'terminal.existing'; Value = 'Terminal existing' }
                )
                Write-ReswFixtureFile -Path (Join-Path $repoPath 'src\cascadia\TerminalApp\Resources\fr-FR\Resources.resw') -Resources @(
                    @{ Name = 'terminal.existing'; Value = 'Terminal existant' }
                )
                $writeSource = {
                    param([object[]]$Entries)
                    Write-WtaFixtureFile -Path $sourcePath -Entries $Entries
                }
                $writeLocale = {
                    param([object[]]$Entries)
                    Write-WtaFixtureFile -Path $localePath -Entries $Entries
                }
            }

            $baseSourceEntries = @(
                @{ Name = 'demo.existing'; Value = 'Base source value' },
                @{ Name = 'demo.legacy'; Value = 'Legacy source value' }
            )
            $baseLocaleEntries = @(
                @{ Name = 'demo.existing'; Value = 'Base locale value' },
                @{ Name = 'demo.legacy'; Value = 'Legacy locale value' }
            )

            $reviewedSourceEntries = $baseSourceEntries
            $reviewedLocaleEntries = $baseLocaleEntries
            $worktreeSourceEntries = $null
            $worktreeLocaleEntries = $null

            switch ($Scenario) {
                'deleted-source' {
                    $baseSourceEntries = @(
                        @{ Name = 'demo.existing'; Value = 'Base source value' }
                    )
                    $baseLocaleEntries = @(
                        @{ Name = 'demo.existing'; Value = 'Base locale value' }
                    )
                    $reviewedSourceEntries = @(
                        @{ Name = 'demo.existing'; Value = 'Base source value' },
                        @{ Name = 'demo.new'; Value = 'Reviewed source addition' }
                    )
                    $reviewedLocaleEntries = @(
                        @{ Name = 'demo.existing'; Value = 'Base locale value' }
                    )
                    $worktreeSourceEntries = $baseSourceEntries
                    $worktreeLocaleEntries = $baseLocaleEntries
                }
                'edited-source' {
                    $baseSourceEntries = @(
                        @{ Name = 'demo.existing'; Value = 'Base source value' }
                    )
                    $baseLocaleEntries = @(
                        @{ Name = 'demo.existing'; Value = 'Base locale value' }
                    )
                    $reviewedSourceEntries = @(
                        @{ Name = 'demo.existing'; Value = 'Reviewed source value' }
                    )
                    $reviewedLocaleEntries = @(
                        @{ Name = 'demo.existing'; Value = 'Reviewed locale value' }
                    )
                    $worktreeSourceEntries = @(
                        @{ Name = 'demo.existing'; Value = 'Worker-mutated source value' }
                    )
                    $worktreeLocaleEntries = $reviewedLocaleEntries
                }
                'missing-locale' {
                    $baseSourceEntries = @(
                        @{ Name = 'demo.existing'; Value = 'Base source value' }
                    )
                    $baseLocaleEntries = @(
                        @{ Name = 'demo.existing'; Value = 'Base locale value' }
                    )
                    $reviewedSourceEntries = @(
                        @{ Name = 'demo.existing'; Value = 'Base source value' },
                        @{ Name = 'demo.new'; Value = 'Reviewed source addition' }
                    )
                    $reviewedLocaleEntries = @(
                        @{ Name = 'demo.existing'; Value = 'Base locale value' }
                    )
                    $worktreeSourceEntries = $reviewedSourceEntries
                    $worktreeLocaleEntries = $reviewedLocaleEntries
                }
                'translated-targets' {
                    $baseSourceEntries = @(
                        @{ Name = 'demo.existing'; Value = 'Base source value' }
                    )
                    $baseLocaleEntries = @(
                        @{ Name = 'demo.existing'; Value = 'Base locale value' }
                    )
                    $reviewedSourceEntries = @(
                        @{ Name = 'demo.existing'; Value = 'Base source value' },
                        @{ Name = 'demo.new'; Value = 'Reviewed source addition' }
                    )
                    $reviewedLocaleEntries = @(
                        @{ Name = 'demo.existing'; Value = 'Base locale value' }
                    )
                    $worktreeSourceEntries = $reviewedSourceEntries
                    $worktreeLocaleEntries = @(
                        @{ Name = 'demo.existing'; Value = 'Base locale value' },
                        @{ Name = 'demo.new'; Value = 'Reviewed locale addition' }
                    )
                }
                'reviewed-source-change-accepted' {
                    $reviewedSourceEntries = @(
                        @{ Name = 'demo.existing'; Value = 'Base source value' }
                    )
                    $reviewedLocaleEntries = @(
                        @{ Name = 'demo.existing'; Value = 'Base locale value' }
                    )
                    $worktreeSourceEntries = $reviewedSourceEntries
                    $worktreeLocaleEntries = $reviewedLocaleEntries
                }
            }

            & $writeSource $baseSourceEntries
            & $writeLocale $baseLocaleEntries
            Invoke-TestGit -RepositoryPath $repoPath -Arguments @('add', '.') | Out-Null
            Invoke-TestGit -RepositoryPath $repoPath -Arguments @('commit', '-m', 'base') | Out-Null
            $baseSha = Invoke-TestGit -RepositoryPath $repoPath -Arguments @('rev-parse', 'HEAD')

            & $writeSource $reviewedSourceEntries
            & $writeLocale $reviewedLocaleEntries
            Invoke-TestGit -RepositoryPath $repoPath -Arguments @('add', '.') | Out-Null
            Invoke-TestGit -RepositoryPath $repoPath -Arguments @('commit', '-m', 'reviewed head') | Out-Null
            $reviewedHeadSha = Invoke-TestGit -RepositoryPath $repoPath -Arguments @('rev-parse', 'HEAD')

            & $writeSource $worktreeSourceEntries
            & $writeLocale $worktreeLocaleEntries

            return [pscustomobject]@{
                RepoPath = $repoPath
                BaseSha = $baseSha
                ReviewedHeadSha = $reviewedHeadSha
                SourcePath = ($sourcePath.Substring($repoPath.Length + 1) -replace '\\', '/')
                LocalePath = ($localePath.Substring($repoPath.Length + 1) -replace '\\', '/')
            }
        }

        function Invoke-ValidationWithReviewedHead {
            param(
                [Parameter(Mandatory)]$Fixture,
                [string]$HeadRevision
            )

            $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
            $arguments = @(
                '-NoLogo',
                '-NoProfile',
                '-NonInteractive',
                '-File',
                $script:checkerScript,
                '-Mode',
                'Validate',
                '-BaseRevision',
                $Fixture.BaseSha,
                '-ReviewedHeadRevision',
                $Fixture.ReviewedHeadSha,
                '-RepositoryRoot',
                $Fixture.RepoPath
            )
            if (-not [string]::IsNullOrWhiteSpace($HeadRevision)) {
                $arguments += @('-HeadRevision', $HeadRevision)
            }

            $lines = & $pwsh @arguments
            $exitCode = $LASTEXITCODE
            $records = @($lines | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
            return [pscustomobject]@{
                ExitCode = $exitCode
                Records = $records
                Summary = $records[-1]
            }
        }
    }
    Describe 'Localization validator completion contract' {
    It 'reads the final JSONL summary line and suppresses follow-up work for exit 64' {
        $jsonlPath = Join-Path $TestDrive 'exit64-summary.jsonl'
        New-LocalizationValidatorJsonl -Path $jsonlPath -Status 'BLOCKED' -Action 'ESCALATE' -ShouldRun $true

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
        $commit = New-LocalizationValidatorCommit -AuthorLogin $null

        Test-LocalizationWorkflowCompletionCommit -Commit $commit -ExpectedHeadSha '0123456789012345678901234567890123456789' |
            Should -BeFalse
    }

    It 'treats a null committer as not-completion' {
        $commit = New-LocalizationValidatorCommit -CommitterLogin $null

        Test-LocalizationWorkflowCompletionCommit -Commit $commit -ExpectedHeadSha '0123456789012345678901234567890123456789' |
            Should -BeFalse
    }

    It 'accepts the verified bot single-parent completion commit' {
        $commit = New-LocalizationValidatorCommit -ParentSha 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

        Test-LocalizationWorkflowCompletionCommit -Commit $commit -ExpectedHeadSha 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' |
            Should -BeTrue
    }
    }

    Describe 'Guide step summary rendering' {
        It 'allows intentional blank summary lines without weakening required argument binding' {
            $workflowPath = Join-Path $PSScriptRoot '..\..\..\workflows\ensure-localizationguide-forkedrepo.md'
            (Get-Content -LiteralPath $workflowPath -Raw) | Should -Match '\[AllowEmptyString\(\)\]\[string\[\]\]\$Lines'

            $summaryPath = Join-Path $TestDrive 'step-summary.md'
            $originalSummary = $env:GITHUB_STEP_SUMMARY
            try {
                $env:GITHUB_STEP_SUMMARY = $summaryPath

                function Write-StepSummary {
                    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)

                    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($Lines -join "`n")
                }

                { Write-StepSummary -Lines @('## Localization review', '', 'Line after blank') } | Should -Not -Throw
                (Get-Content -LiteralPath $summaryPath -Raw) | Should -Match "## Localization review`r?`n`r?`nLine after blank"
                { Write-StepSummary } | Should -Throw
            } finally {
                $env:GITHUB_STEP_SUMMARY = $originalSummary
            }
        }
    }

    Describe 'Reviewed source locale preservation' {
        It 'keeps an immutable reviewed source authority when a new source key is deleted locally' -TestCases @(
            @{ Kind = 'resw' }
            @{ Kind = 'wta' }
        ) {
            param([string]$Kind)

            $fixture = New-ReviewedSourceScenario -Kind $Kind -Scenario 'deleted-source'
            $result = Invoke-ValidationWithReviewedHead -Fixture $fixture

            $result.ExitCode | Should -Be 20
            $result.Summary.status | Should -Be 'FIXABLE'
            @($result.Records | Where-Object { $_.kind -eq 'check' -and $_.check_id -eq 'validate.source-locale-preserved' }).Count | Should -BeGreaterThan 0
        }

        It 'rejects source value edits that drift from the reviewed head' -TestCases @(
            @{ Kind = 'resw' }
            @{ Kind = 'wta' }
        ) {
            param([string]$Kind)

            $fixture = New-ReviewedSourceScenario -Kind $Kind -Scenario 'edited-source'
            $result = Invoke-ValidationWithReviewedHead -Fixture $fixture

            $result.ExitCode | Should -Be 20
            $result.Summary.status | Should -Be 'FIXABLE'
            @($result.Records | Where-Object { $_.kind -eq 'check' -and $_.check_id -eq 'validate.source-locale-preserved' }).Count | Should -BeGreaterThan 0
        }

        It 'reports missing localized targets as fixable when the reviewed source stays intact' -TestCases @(
            @{ Kind = 'resw' }
            @{ Kind = 'wta' }
        ) {
            param([string]$Kind)

            $fixture = New-ReviewedSourceScenario -Kind $Kind -Scenario 'missing-locale'
            $result = Invoke-ValidationWithReviewedHead -Fixture $fixture

            $result.ExitCode | Should -Be 20
            $result.Summary.status | Should -Be 'FIXABLE'
            @($result.Records | Where-Object { $_.kind -eq 'check' -and $_.check_id -match 'key-parity' }).Count | Should -BeGreaterThan 0
            @($result.Records | Where-Object { $_.kind -eq 'check' -and $_.check_id -eq 'validate.source-locale-preserved' }).Count | Should -Be 0
        }

        It 'passes once translated targets are added without changing the reviewed source' -TestCases @(
            @{ Kind = 'resw' }
            @{ Kind = 'wta' }
        ) {
            param([string]$Kind)

            $fixture = New-ReviewedSourceScenario -Kind $Kind -Scenario 'translated-targets'
            $result = Invoke-ValidationWithReviewedHead -Fixture $fixture

            $result.ExitCode | Should -Be 0
            $result.Summary.status | Should -Be 'PASS'
            @($result.Records | Where-Object { $_.kind -eq 'check' -and $_.status -ne 'PASS' }).Count | Should -Be 0
        }

        It 'accepts legitimate source edits or removals when the worktree still matches the reviewed head' -TestCases @(
            @{ Kind = 'resw' }
            @{ Kind = 'wta' }
        ) {
            param([string]$Kind)

            $fixture = New-ReviewedSourceScenario -Kind $Kind -Scenario 'reviewed-source-change-accepted'
            $result = Invoke-ValidationWithReviewedHead -Fixture $fixture

            $result.ExitCode | Should -Be 0
            $result.Summary.status | Should -Be 'PASS'
            @($result.Records | Where-Object { $_.kind -eq 'check' -and $_.check_id -eq 'validate.source-locale-preserved' }).Count | Should -Be 0
        }
    }

    Describe 'WTA locked token validation' {
        BeforeAll {
            $fixtureBytes = New-Utf8Bytes -Text @'
# ── File-level locks ─────────────────────────────────────────────────────────
# {Locked=qps-ploc,qps-ploca,qps-plocm} "Intelligent Terminal" is the product name

demo.clean_c.visible_review: "GHAW Visible Review" # {Locked}
demo.clean_c.visible_review_with_product: "GHAW Visible Review — Intelligent Terminal"
'@
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
