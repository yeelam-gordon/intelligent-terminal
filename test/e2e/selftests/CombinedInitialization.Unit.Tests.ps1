#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    $script:ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot '..\tests\Feature.CombinedAgentsSidebar.Tests.ps1'), [ref]$null, [ref]$null)
}

Describe 'Combined sidebar supported filter actions' -Tag 'Unit' {
    BeforeAll {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        $definition = $script:ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Set-CombinedFilters'
        }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        function Get-CombinedFilterState { $script:filterState.Clone() }
        function Invoke-UiClick { param($App, $Selector) }
        function Get-CombinedElement {
            param($Id)
            $peer = [pscustomobject]@{ Id = $Id }
            $peer | Add-Member ScriptMethod GetCurrentPattern {
                param($pattern)
                if ($pattern -ne [Windows.Automation.TogglePattern]::Pattern) {
                    throw 'Unsupported Pattern'
                }
                $script:patternRequests.Add($this.Id)
                $toggle = [pscustomobject]@{ Id = $this.Id }
                $toggle | Add-Member ScriptMethod Toggle {
                    $script:toggleCalls.Add($this.Id)
                    if (-not $script:ignoreToggle) {
                        $script:filterState[$this.Id] = -not $script:filterState[$this.Id]
                    }
                }
                $toggle
            }
            $peer
        }
        function Assert-CombinedHeaderCue { param($Expected) }
    }

    BeforeEach {
        $script:app = @{ Pid = 42 }
        $script:filterState = @{
            AgentsOnlyFilterMenuItem = $false
            RecentAgentSessionsFilterMenuItem = $false
        }
        $script:patternRequests = [Collections.Generic.List[string]]::new()
        $script:toggleCalls = [Collections.Generic.List[string]]::new()
        $script:ignoreToggle = $false
        Mock Invoke-UiClick {
            $Selector | Should -Be FilterTabsButton
            $App.Pid | Should -Be 42
        }
        Mock Assert-CombinedHeaderCue { $Expected | Should -Be Tabs }
    }

    It 'toggles each mismatching named filter once and leaves matching state untouched' {
        Set-CombinedFilters -AgentsOnly $true -Recent $false
        $script:toggleCalls.ToArray() | Should -Be @('AgentsOnlyFilterMenuItem')
        Set-CombinedFilters -AgentsOnly $true -Recent $true
        $script:toggleCalls.ToArray() | Should -Be @(
            'AgentsOnlyFilterMenuItem', 'RecentAgentSessionsFilterMenuItem')
        Set-CombinedFilters -AgentsOnly $true -Recent $true
        $script:toggleCalls.Count | Should -Be 2
        Set-CombinedFilters -AgentsOnly $false -Recent $false
        $script:toggleCalls.ToArray() | Should -Be @(
            'AgentsOnlyFilterMenuItem', 'RecentAgentSessionsFilterMenuItem',
            'AgentsOnlyFilterMenuItem', 'RecentAgentSessionsFilterMenuItem')
        $script:patternRequests.ToArray() | Should -Be $script:toggleCalls.ToArray()
        $script:filterState.AgentsOnlyFilterMenuItem | Should -BeFalse
        $script:filterState.RecentAgentSessionsFilterMenuItem | Should -BeFalse
        Should -Invoke Invoke-UiClick -Exactly -Times 4
        Should -Invoke Assert-CombinedHeaderCue -Exactly -Times 4
    }

    It 'fails the retained final state assertion when <Id> does not change' -ForEach @(
        @{ Id = 'AgentsOnlyFilterMenuItem'; AgentsOnly = $true; Recent = $false },
        @{ Id = 'RecentAgentSessionsFilterMenuItem'; AgentsOnly = $false; Recent = $true }
    ) {
        $script:ignoreToggle = $true
        { Set-CombinedFilters -AgentsOnly $AgentsOnly -Recent $Recent } | Should -Throw
        $script:toggleCalls.ToArray() | Should -Be @($Id)
        Should -Invoke Assert-CombinedHeaderCue -Exactly -Times 0
    }
}

Describe 'Combined sidebar initialization order' -Tag 'Unit' {
    It 'file-level BeforeAll defines helpers without accessing package paths' {
        $parent = $script:ast.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.PipelineAst] -and $_.PipelineElements[0].GetCommandName() -eq 'BeforeAll'
        } | Select-Object -First 1
        $body = $parent.PipelineElements[0].CommandElements[1].ScriptBlock
        @($body.EndBlock.Statements | Where-Object {
            $_ -isnot [Management.Automation.Language.FunctionDefinitionAst]
        }).Count | Should -Be 0
        $script:target = $null
        $script:evidence = $null
        $text = $body.Extent.Text
        { . ([scriptblock]::Create($text.Substring(1, $text.Length - 2))) } | Should -Not -Throw
    }

    It 'snapshots runtime state after provenance but before any fixture or app mutation' {
        $text = $script:ast.Extent.Text
        $call = $text.IndexOf("`n        Initialize-CombinedRuntimeBackup")
        $call | Should -BeGreaterOrEqual 0
        foreach ($marker in @(
            '$script:target = Resolve-ItApp',
            'Refusing to adopt or close an existing Dev process',
            'New-Item -ItemType Directory -Path $script:evidence',
            "'package-before-launch.json'"
        )) {
            $position = $text.IndexOf($marker)
            $position | Should -BeGreaterOrEqual 0 -Because "the prerequisite marker must exist: $marker"
            $call | Should -BeGreaterThan $position
        }
        foreach ($marker in @('$script:historyPath = Join-Path', 'Start-Terminal -Package Dev')) {
            $position = $text.IndexOf($marker)
            $position | Should -BeGreaterOrEqual 0 -Because "the mutation marker must exist: $marker"
            $call | Should -BeLessThan $position
        }
    }
}
