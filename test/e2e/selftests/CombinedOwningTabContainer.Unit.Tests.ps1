#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    $script:suite = Join-Path $PSScriptRoot '..\tests\Feature.CombinedAgentsSidebar.Tests.ps1'
    $script:suiteAst = [Management.Automation.Language.Parser]::ParseFile(
        $script:suite, [ref]$null, [ref]$null)
    $script:originalHistoryMode = $env:ITE2E_HISTORY_INDICATORS_ONLY
    function Get-CombinedModeAssignment([string]$Name) {
        $node = $script:suiteAst.Find({ param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                $node.Left.VariablePath.UserPath -eq $Name
        }, $true)
        $node | Should -Not -BeNullOrEmpty
        $node.Extent.Text
    }
}

Describe 'Combined owning-tab container selection' -Tag 'Unit' {
    AfterAll { $env:ITE2E_HISTORY_INDICATORS_ONLY = $script:originalHistoryMode }

    It 'discovers <Count> cases for <Mode> without running live setup' -ForEach @(
        @{ Mode = 'default'; Focused = $false; History = ''; Count = 33 },
        @{ Mode = 'owning-tab only'; Focused = $true; History = ''; Count = 1 },
        @{ Mode = 'history compatibility'; Focused = $false; History = '1'; Count = 33 },
        @{ Mode = 'focused history compatibility'; Focused = $true; History = '1'; Count = 1 }
    ) {
        $env:ITE2E_HISTORY_INDICATORS_ONLY = $History
        $configuration = New-PesterConfiguration
        $configuration.Run.Container = if ($Mode -eq 'default') {
            New-PesterContainer -Path $script:suite
        } else {
            New-PesterContainer -Path $script:suite -Data @{ OwningTabMoveOnly = $Focused }
        }
        $configuration.Run.SkipRun = $true
        $configuration.Run.PassThru = $true
        $configuration.Output.Verbosity = 'None'
        $result = Invoke-Pester -Configuration $configuration
        $result.TotalCount | Should -Be $Count
        $result.FailedCount | Should -Be 0
        @($result.Tests | Where-Object Executed) | Should -HaveCount 0
        if ($Focused) {
            @($result.Tests).Name | Should -Be 'Agents view moves whole owning tabs without changing sessions'
        }
    }

    It 'preserves setup and scrolling branches for <Mode>' -ForEach @(
        @{ Mode = 'default'; Focused = $false; History = ''; Seeds = 8; Survival = 30; Scrolls = 1 },
        @{ Mode = 'owning-tab only'; Focused = $true; History = ''; Seeds = 0; Survival = 0; Scrolls = 1 },
        @{ Mode = 'history compatibility'; Focused = $false; History = '1'; Seeds = 0; Survival = 0; Scrolls = 0 },
        @{ Mode = 'focused history compatibility'; Focused = $true; History = '1'; Seeds = 0; Survival = 0; Scrolls = 0 }
    ) {
        $OwningTabMoveOnly = $Focused
        $env:ITE2E_HISTORY_INDICATORS_ONLY = $History
        . ([scriptblock]::Create((Get-CombinedModeAssignment survivalSeconds)))
        . ([scriptblock]::Create((Get-CombinedModeAssignment seedIndices)))
        . ([scriptblock]::Create((Get-CombinedModeAssignment scrollLists)))
        $survivalSeconds | Should -Be $Survival
        @($seedIndices) | Should -HaveCount $Seeds
        @($scrollLists) | Should -HaveCount $Scrolls
    }
}
