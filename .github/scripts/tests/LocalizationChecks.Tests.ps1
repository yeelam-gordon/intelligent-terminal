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
}
