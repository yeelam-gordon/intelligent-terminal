#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\..\.github\scripts\localization_validator_output.ps1')
    $script:exit64Fixture = Join-Path $PSScriptRoot 'fixtures\localization-validator\exit64-summary.jsonl'
}

Describe 'Localization validator consumer' -Tag 'Unit' {
    It 'accepts exit 64 when the summary is BLOCKED/ESCALATE and suppresses follow-up work' {
        $result = Resolve-LocalizationValidatorCompletion -JsonlPath $script:exit64Fixture -ExitCode 64

        $result.Summary.status | Should -Be 'BLOCKED'
        $result.Summary.action | Should -Be 'ESCALATE'
        $result.ShouldRun | Should -BeFalse
    }

    It 'throws on unexpected exit codes before trusting the summary payload' {
        { Resolve-LocalizationValidatorCompletion -JsonlPath $script:exit64Fixture -ExitCode 99 } |
            Should -Throw '*Unexpected localization validator exit code: 99*'
    }
}
