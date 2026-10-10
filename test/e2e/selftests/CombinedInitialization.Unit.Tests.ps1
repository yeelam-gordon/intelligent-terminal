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
        $core = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot '..\ItE2E\Private\Core.ps1'), [ref]$null, [ref]$null)
        $wait = $core.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Wait-Until'
        }, $true)
        . ([scriptblock]::Create($wait.Extent.Text))
        function Get-CombinedFilterState { $script:filterState.Clone() }
        function Invoke-UiClick { param($App, $Selector) }
        function Get-CombinedElement {
            param($Id)
            $script:peerRequests.Add($Id)
            $script:peerReads++
            if ($script:peerReads -le $script:pendingReads) { return $null }
            $peer = [pscustomobject]@{
                Id = $Id
                Current = [pscustomobject]@{
                    ProcessId = $script:peerPid
                    ControlType = $script:peerType
                    IsOffscreen = $script:peerReads -le ($script:pendingReads + $script:offscreenReads)
                }
            }
            $peer | Add-Member ScriptMethod GetCurrentPattern {
                param($pattern)
                if ($script:unsupportedPattern -or $pattern -ne [Windows.Automation.TogglePattern]::Pattern) {
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
        $script:peerRequests = [Collections.Generic.List[string]]::new()
        $script:peerReads = 0
        $script:pendingReads = 0
        $script:offscreenReads = 0
        $script:peerPid = 42
        $script:peerType = [Windows.Automation.ControlType]::MenuItem
        $script:unsupportedPattern = $false
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

    It 'waits for the exact <Id> peer to become present and visible before toggling' -ForEach @(
        @{ Id = 'AgentsOnlyFilterMenuItem'; AgentsOnly = $true; Recent = $false },
        @{ Id = 'RecentAgentSessionsFilterMenuItem'; AgentsOnly = $false; Recent = $true }
    ) {
        $script:pendingReads = 1
        $script:offscreenReads = 1
        Set-CombinedFilters -AgentsOnly $AgentsOnly -Recent $Recent
        $script:peerRequests.ToArray() | Should -Be @($Id, $Id, $Id)
        $script:toggleCalls.ToArray() | Should -Be @($Id)
        $script:filterState[$Id] | Should -BeTrue
        Should -Invoke Invoke-UiClick -Exactly -Times 1
        Should -Invoke Assert-CombinedHeaderCue -Exactly -Times 1
    }

    It 'rejects a visible peer from another process before requesting its pattern' {
        $script:peerPid = 43
        { Set-CombinedFilters -AgentsOnly $true -Recent $false } | Should -Throw
        $script:patternRequests.Count | Should -Be 0
        $script:toggleCalls.Count | Should -Be 0
    }

    It 'rejects a visible non-menu peer before requesting its pattern' {
        $script:peerType = [Windows.Automation.ControlType]::Button
        { Set-CombinedFilters -AgentsOnly $true -Recent $false } | Should -Throw
        $script:patternRequests.Count | Should -Be 0
        $script:toggleCalls.Count | Should -Be 0
    }

    It 'fails explicitly when the visible menu peer does not support TogglePattern' {
        $script:unsupportedPattern = $true
        { Set-CombinedFilters -AgentsOnly $true -Recent $false } | Should -Throw '*Unsupported Pattern*'
        $script:toggleCalls.Count | Should -Be 0
        Should -Invoke Assert-CombinedHeaderCue -Exactly -Times 0
    }

    It 'retains the 30-second bound when the peer never becomes ready' {
        Mock Wait-Until {
            $TimeoutSec | Should -Be 30
            $Because | Should -Be 'AgentsOnlyFilterMenuItem is visible in the owned filter flyout'
            & $Condition | Should -BeNullOrEmpty
            throw 'Wait-Until timed out after 30s waiting for: AgentsOnlyFilterMenuItem'
        }
        $script:pendingReads = 1
        { Set-CombinedFilters -AgentsOnly $true -Recent $false } | Should -Throw '*timed out after 30s*'
        $script:toggleCalls.Count | Should -Be 0
        Should -Invoke Wait-Until -Exactly -Times 1
        Should -Invoke Assert-CombinedHeaderCue -Exactly -Times 0
    }
}

Describe 'Combined sidebar initialization order' -Tag 'Unit' {
    It 'keeps the C425 ordinary neighbor stashed while waiting for the two agent tabs' {
        $case = $script:ast.Find({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'It' -and
                $node.CommandElements[1].Value -eq 'Agents view moves whole owning tabs without changing sessions'
        }, $true)
        $case | Should -Not -BeNullOrEmpty
        $commands = @($case.FindAll({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Wait-AgentReady'
        }, $true))
        $commands | Should -HaveCount 2
        $targets = @(foreach ($command in $commands) {
            $parameter = @($command.CommandElements | Where-Object {
                $_ -is [Management.Automation.Language.CommandParameterAst] -and
                    $_.ParameterName -eq 'PaneSessionId'
            })
            $parameter | Should -HaveCount 1
            $argument = $command.CommandElements[$command.CommandElements.IndexOf($parameter[0]) + 1]
            $argument | Should -BeOfType ([Management.Automation.Language.MemberExpressionAst])
            $argument.Member.Value | Should -Be PaneSessionId
            $argument.Expression.VariablePath.UserPath
        })
        $targets | Should -Be @('neighborHelper', 'helper')
        $ordinaryCapture = @($case.FindAll({ param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.VariablePath.UserPath -eq 'ordinaryHelper'
        }, $true))
        $ordinaryCapture | Should -HaveCount 1
        @($ordinaryCapture[0].FindAll({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Wait-NewAgentPaneSession'
        }, $true)) | Should -HaveCount 1
    }

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
