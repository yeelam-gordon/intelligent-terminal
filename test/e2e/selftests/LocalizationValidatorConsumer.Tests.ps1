#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\ItE2E\ItE2E.psd1') -Force
    $script:resolverScript = Join-Path $PSScriptRoot '..\..\..\.github\scripts\localization_checks.ps1'
    . $script:resolverScript

    $script:fixtureRoot = Join-Path $PSScriptRoot 'fixtures\localization-validator'
    $script:generatedRoot = Join-Path $PSScriptRoot 'fixtures\localization-validator\generated'
    New-Item -ItemType Directory -Force -Path $script:generatedRoot | Out-Null

    function Get-LocalizationValidatorCommitFixture {
        param([Parameter(Mandatory)][string]$Name)

        $fixturePath = Join-Path $script:fixtureRoot $Name
        Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json -AsHashtable
    }

    $script:childScript = Join-Path $script:generatedRoot 'validator-child.ps1'
    @'
param(
    [Parameter(Mandatory)][string]$Status,
    [Parameter(Mandatory)][string]$Action,
    [Parameter(Mandatory)][bool]$ShouldRun,
    [Parameter(Mandatory)][int]$ExitCode,
    [Parameter(Mandatory)][string]$StdErrMessage
)

$record = [ordered]@{
    kind = 'summary'
    mode = 'Validate'
    status = $Status
    action = $Action
    should_run = $ShouldRun
    check_id = 'input.validation'
    file = $null
    resource = $null
    observed = $null
    expected = $null
    message = 'child validator summary'
    suggested_action = $null
    comparison_base = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
    total_count = 0
    pass_count = 0
    fixable_count = 0
    blocked_count = 0
}

$record | ConvertTo-Json -Compress -Depth 6
Write-Error -Message $StdErrMessage -ErrorAction Continue
exit $ExitCode
'@ | Set-Content -LiteralPath $script:childScript -Encoding utf8

    $script:consumerScript = Join-Path $script:generatedRoot 'validator-consumer.ps1'
    @'
param(
    [Parameter(Mandatory)][string]$ChildScriptPath,
    [Parameter(Mandatory)][string]$ResolverScriptPath,
    [Parameter(Mandatory)][string]$JsonlPath,
    [ValidateSet('controller', 'validate')][string]$ConsumerKind,
    [Parameter(Mandatory)][string]$Status,
    [Parameter(Mandatory)][string]$Action,
    [Parameter(Mandatory)][bool]$ShouldRun,
    [Parameter(Mandatory)][int]$ExitCode,
    [Parameter(Mandatory)][string]$StdErrMessage
)

$previousNativePreference = $PSNativeCommandUseErrorActionPreference
$PSNativeCommandUseErrorActionPreference = $false
try {
    & pwsh -NoLogo -NoProfile -NonInteractive -File $ChildScriptPath -Status $Status -Action $Action -ShouldRun:$ShouldRun -ExitCode $ExitCode.ToString() -StdErrMessage $StdErrMessage |
        Tee-Object -FilePath $JsonlPath | Out-Null
    $childExitCode = $LASTEXITCODE

. $ResolverScriptPath
$resolvedAllowedExitCodes = if ($ConsumerKind -eq 'controller') {
    @(0, 10, 30, 64)
} else {
    @(0, 20, 30, 64)
}
$completion = Resolve-LocalizationValidatorCompletion -JsonlPath $JsonlPath -ExitCode $childExitCode -AllowedExitCodes $resolvedAllowedExitCodes
[pscustomobject]@{
    exit_code = $childExitCode
    status = $completion.Summary.status
    action = $completion.Summary.action
    should_run = $completion.ShouldRun
} | ConvertTo-Json -Compress -Depth 6
Write-Output 'CONTINUATION_MARKER'
}
finally {
    $PSNativeCommandUseErrorActionPreference = $previousNativePreference
}
'@ | Set-Content -LiteralPath $script:consumerScript -Encoding utf8

    Set-Item -Path function:Invoke-LocalizationValidatorConsumerBoundary -Value {
        param(
            [Parameter(Mandatory)][string]$Status,
            [Parameter(Mandatory)][string]$Action,
            [Parameter(Mandatory)][bool]$ShouldRun,
            [Parameter(Mandatory)][int]$ExitCode,
            [ValidateSet('controller', 'validate')][string]$ConsumerKind
        )

        $jsonlPath = Join-Path $script:generatedRoot ("boundary-{0}-{1}.jsonl" -f $Status.ToLowerInvariant(), $ExitCode)
        Remove-Item -LiteralPath $jsonlPath -Force -ErrorAction SilentlyContinue

        $arguments = @(
            '-NoLogo'
            '-NoProfile'
            '-NonInteractive'
            '-File'
            $script:consumerScript
            '-ChildScriptPath'
            $script:childScript
            '-ResolverScriptPath'
            $script:resolverScript
            '-JsonlPath'
            $jsonlPath
            '-ConsumerKind'
            $ConsumerKind
            '-Status'
            $Status
            '-Action'
            $Action
            "-ShouldRun:$($ShouldRun.ToString().ToLowerInvariant())"
            '-ExitCode'
            $ExitCode.ToString()
            '-StdErrMessage'
            "stderr-$Status"
        )

        Invoke-Native -FilePath 'pwsh' -Arguments $arguments -TimeoutSec 30
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:generatedRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Localization validator consumer' -Tag 'Unit' {
    It 'builds a scoped GitHub extraheader for transient authenticated fetches' {
        $config = Get-GitHubScopedExtraHeaderConfig -RemoteUrl 'https://github.com/yeelam-gordon/intelligent-terminal-ghaw-test.git' -Token 'test-token'

        $config | Should -Match '^http\.https://github\.com/\.extraheader=AUTHORIZATION: basic '

        $encodedCredential = $config.Substring($config.LastIndexOf(' ') + 1)
        [System.Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($encodedCredential)) |
            Should -Be 'x-access-token:test-token'
    }

    It 'rejects GitHub git auth setup when GH_TOKEN is missing or the remote is not https' {
        { Get-GitHubScopedExtraHeaderConfig -RemoteUrl 'https://github.com/yeelam-gordon/intelligent-terminal-ghaw-test.git' -Token '' } |
            Should -Throw '*GH_TOKEN is required*'
        { Get-GitHubScopedExtraHeaderConfig -RemoteUrl 'git@github.com:yeelam-gordon/intelligent-terminal-ghaw-test.git' -Token 'test-token' } |
            Should -Throw '*must be an https remote*'
    }

    It 'accepts exit 64 when the summary is BLOCKED/ESCALATE and suppresses follow-up work' {
        $result = Resolve-LocalizationValidatorCompletion -JsonlPath (Join-Path $PSScriptRoot 'fixtures\localization-validator\exit64-summary.jsonl') -ExitCode 64

        $result.Summary.status | Should -Be 'BLOCKED'
        $result.Summary.action | Should -Be 'ESCALATE'
        $result.ShouldRun | Should -BeFalse
    }

    It 'throws on unexpected exit codes before trusting the summary payload' {
        { Resolve-LocalizationValidatorCompletion -JsonlPath (Join-Path $PSScriptRoot 'fixtures\localization-validator\exit64-summary.jsonl') -ExitCode 99 } |
            Should -Throw '*Unexpected localization validator exit code: 99*'
    }

    It 'runs the native pwsh boundary for all supported consumer statuses and continues past the child process' {
        $cases = @(
            @{
                Name = 'controller-review'
                Status = 'PASS'
                Action = 'REVIEW'
                ShouldRun = $true
                CompletionShouldRun = $true
                ExitCode = 10
                ConsumerKind = 'controller'
            }
            @{
                Name = 'controller-pass'
                Status = 'PASS'
                Action = 'NONE'
                ShouldRun = $false
                CompletionShouldRun = $false
                ExitCode = 0
                ConsumerKind = 'controller'
            }
            @{
                Name = 'worker-fixable'
                Status = 'FIXABLE'
                Action = 'FIX'
                ShouldRun = $true
                CompletionShouldRun = $true
                ExitCode = 20
                ConsumerKind = 'validate'
            }
            @{
                Name = 'worker-blocked'
                Status = 'BLOCKED'
                Action = 'ESCALATE'
                ShouldRun = $true
                CompletionShouldRun = $false
                ExitCode = 30
                ConsumerKind = 'validate'
            }
            @{
                Name = 'worker-invalid-input'
                Status = 'BLOCKED'
                Action = 'ESCALATE'
                ShouldRun = $true
                CompletionShouldRun = $false
                ExitCode = 64
                ConsumerKind = 'validate'
            }
        )

        foreach ($case in $cases) {
            $result = Invoke-LocalizationValidatorConsumerBoundary -Status $case.Status -Action $case.Action -ShouldRun $case.ShouldRun -ExitCode $case.ExitCode -ConsumerKind $case.ConsumerKind

            $result.ExitCode | Should -Be 0

            $stdoutLines = @($result.StdOut -split "`r?`n" | Where-Object { $_ })
            $stdoutLines[-1] | Should -Be 'CONTINUATION_MARKER'

            $payload = $stdoutLines[0] | ConvertFrom-Json
            $payload.exit_code | Should -Be $case.ExitCode
            $payload.status | Should -Be $case.Status
            $payload.action | Should -Be $case.Action
            $payload.should_run | Should -Be $case.CompletionShouldRun

            $result.StdErr | Should -Match "stderr-$($case.Status)"

            $jsonlPath = Join-Path $script:generatedRoot ("boundary-{0}-{1}.jsonl" -f $case.Status.ToLowerInvariant(), $case.ExitCode)
            $jsonlLines = @(Get-Content -LiteralPath $jsonlPath)
            $jsonlLines.Count | Should -Be 1
            $jsonlRecord = $jsonlLines[0] | ConvertFrom-Json
            $jsonlRecord.status | Should -Be $case.Status
            $jsonlRecord.should_run | Should -Be $case.ShouldRun
        }
    }

    It 'can dot-source the shared checker without running Gate or Validate' {
        Get-Command Resolve-LocalizationValidatorCompletion -CommandType Function -ErrorAction Stop |
            Select-Object -ExpandProperty Name |
            Should -Be 'Resolve-LocalizationValidatorCompletion'
    }
}

Describe 'Localization workflow provenance gate' -Tag 'Unit' {
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

    It 'fails closed on malformed API error payloads' {
        { Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'commit-malformed-api-error.txt') -Raw | ConvertFrom-Json -AsHashtable } |
            Should -Throw
    }
}
