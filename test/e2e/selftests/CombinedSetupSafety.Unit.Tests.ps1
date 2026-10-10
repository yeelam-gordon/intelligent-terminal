#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '..\ItE2E\ItE2E.psd1') -Force
    & (Get-Module ItE2E) { param($Root) $script:CombinedSetupSelfTestRoot = $Root } $PSScriptRoot
}

Describe 'Combined sidebar common setup preserves user configuration' -Tag 'Unit' {
InModuleScope ItE2E {
BeforeAll {
    $errors = $null
    $script:sourceAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $script:CombinedSetupSelfTestRoot '..\tests\Feature.CombinedAgentsSidebar.Tests.ps1'), [ref]$null, [ref]$errors)
    if ($errors) { throw "Feature source parse failed: $errors" }
    $describe = $script:sourceAst.EndBlock.Statements |
        Where-Object { $_ -is [Management.Automation.Language.PipelineAst] -and
            $_.PipelineElements[0].GetCommandName() -eq 'Describe' } | Select-Object -First 1
    $blocks = $describe.PipelineElements[0].CommandElements[-1].ScriptBlock.EndBlock.Statements
    $before = ($blocks | Where-Object { $_ -is [Management.Automation.Language.PipelineAst] -and
        $_.PipelineElements[0].GetCommandName() -eq 'BeforeAll' }).PipelineElements[0].CommandElements[-1].ScriptBlock
    $statements = @($before.EndBlock.Statements)
    $first = @($statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
        $_.Left.Extent.Text -eq '$startupState' })[0]
    $last = @($statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
        $_.Left.Extent.Text -eq '$script:app' -and $_.Right.Extent.Text -match '^Start-Terminal' })[0]
    if (-not $first -or -not $last) { throw 'Exact common setup AST boundaries are missing.' }
    $script:setup = [scriptblock]::Create($script:sourceAst.Extent.Text.Substring(
        $first.Extent.StartOffset, $last.Extent.EndOffset - $first.Extent.StartOffset))
    $after = ($blocks | Where-Object { $_ -is [Management.Automation.Language.PipelineAst] -and
        $_.PipelineElements[0].GetCommandName() -eq 'AfterAll' }).PipelineElements[0].CommandElements[-1].ScriptBlock
    $cleanupTry = @($after.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.TryStatementAst] })[0]
    $script:recovery = [scriptblock]::Create($cleanupTry.Finally.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))
}

    BeforeEach {
        $script:fixture = Join-Path $script:CombinedSetupSelfTestRoot ("..\artifacts\combined-setup-safety-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:fixture -Force | Out-Null
        $script:target = [pscustomobject]@{
            SettingsPath = Join-Path $script:fixture 'settings.json'
            StatePath = Join-Path $script:fixture 'state.json'
        }
        $settings = @'
// Preserve comments and original bytes on recovery.
{
  "acpAgent": "user-agent",
  "delegateAgent": "user-delegate",
  "aiIntegration.coordinator.enabled": true,
  "aiIntegration.custom": {"nested": {"keep": [1, {"value": "sentinel"}]}},
  "profiles": {"defaults": {"font": {"face": "User Font"}}, "list": [{"guid": "{12345678-1234-1234-1234-123456789abc}", "name": "User profile", "commandline": "user-shell"}]},
  "actions": [{"command": {"action": "sendInput", "input": "user-action"}, "keys": "ctrl+alt+u"}],
  "keybindings": [{"command": "paste", "keys": "ctrl+shift+v"}],
  "custom": {"nested": {"array": ["keep"]}}
}
'@
        [IO.File]::WriteAllText($script:target.SettingsPath, $settings, [Text.UTF8Encoding]::new($true))
        [IO.File]::WriteAllText($script:target.StatePath,
            '{"userState":{"nested":["retain"]},"sidebarLayoutMigrationCompleted":false}', [Text.UTF8Encoding]::new($true))
        $script:originalHashes = @{}
        foreach ($path in @($script:target.SettingsPath, $script:target.StatePath)) {
            $script:originalHashes[$path] = (Get-FileHash -LiteralPath $path).Hash
        }
        $script:originalSettings = Get-WtSettingsObject -App $script:target
        $script:ownsConfig = $false
        $script:app = $null
        $script:cleanupError = $null
        $script:runtimeStateExisted = $false
        $script:runtimeStatePath = Join-Path $script:fixture 'runtime'
        $command = 'owned-fixture-command'
        Mock Write-ItLog {}
        Mock Get-WtProcessesForApp { @() }
        Mock Clear-WtConfig { throw 'Settings clearing is forbidden.' }
        Mock Wait-Until { if (-not (& $Condition)) { throw 'Settings verification failed.' }; $true }
        Mock Start-Terminal {
            if ($Package -cne 'Dev' -or $Backup -ne $false -or $CleanSettings -ne $false -or $PassFre -ne $true) {
                throw 'Unexpected launch configuration.'
            }
            Invoke-FrePass -App $script:target | Out-Null
            Set-WtSettings -App $script:target -Settings $Settings | Out-Null
            $script:target
        }
    }

    AfterEach {
        # Only this hermetic fixture is discarded; no package or user paths are accessed.
        Remove-Item -LiteralPath $script:fixture -Recurse -Force
    }

    It 'executes exact setup objects, targeted real merges, and checked byte-identical recovery' {
        @($script:sourceAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Clear-WtConfig'
        }, $true)).Count | Should -Be 0
        . $script:setup
        $script:ownsConfig | Should -BeTrue
        $actual = Get-WtSettingsObject -App $script:target
        foreach ($key in @('profiles', 'actions', 'keybindings', 'delegateAgent',
            'aiIntegration.coordinator.enabled', 'aiIntegration.custom', 'custom')) {
            ConvertTo-Json -InputObject $actual.$key -Depth 64 -Compress |
                Should -Be (ConvertTo-Json -InputObject $script:originalSettings.$key -Depth 64 -Compress)
        }
        $actual.acpAgent | Should -Be 'custom:combined-sidebar-fixture'
        $actual.acpCustomCommand | Should -Be 'owned-fixture-command'
        $state = Get-WtStateObject -App $script:target
        $state.userState.nested[0] | Should -Be 'retain'
        $state.sidebarLayoutMigrationCompleted | Should -BeTrue
        $state.agentFreCompleted | Should -BeTrue
        Should -Invoke Clear-WtConfig -Times 0 -Exactly
        Should -Invoke Start-Terminal -Times 1 -Exactly -ParameterFilter {
            $CleanSettings -eq $false -and $Backup -eq $false -and
            -not $Settings.ContainsKey('actions') -and -not $Settings.ContainsKey('keybindings') -and
            -not $Settings.ContainsKey('profiles')
        }
        . $script:recovery
        foreach ($path in $script:originalHashes.Keys) {
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $script:originalHashes[$path]
            Test-Path "$path.e2ebak" | Should -BeFalse
        }
    }

    It 'refuses changed configuration before backup or launch without overwriting it' {
        [IO.File]::AppendAllText($script:target.SettingsPath, "`r`n// newer user edit")
        $newHash = (Get-FileHash -LiteralPath $script:target.SettingsPath).Hash
        { . $script:setup } | Should -Throw '*newer user state*'
        (Get-FileHash -LiteralPath $script:target.SettingsPath).Hash | Should -Be $newHash
        $script:ownsConfig | Should -BeFalse
        Test-Path "$($script:target.SettingsPath).e2ebak" | Should -BeFalse
        Should -Invoke Start-Terminal -Times 0
    }

    It 'refuses stale backup markers without replaying them' {
        [IO.File]::WriteAllText("$($script:target.SettingsPath).e2ebak", 'foreign backup')
        { . $script:setup } | Should -Throw '*never replay*'
        (Get-FileHash -LiteralPath $script:target.SettingsPath).Hash | Should -Be $script:originalHashes[$script:target.SettingsPath]
        Get-Content -LiteralPath "$($script:target.SettingsPath).e2ebak" -Raw | Should -Be 'foreign backup'
        $script:ownsConfig | Should -BeFalse
        Should -Invoke Start-Terminal -Times 0
    }

    It 'refuses an active package before acquiring backup ownership or applying overlays' {
        Mock Get-WtProcessesForApp { [pscustomobject]@{ Id = 42 } }
        { . $script:setup } | Should -Throw '*Dev started during preparation*'
        $script:ownsConfig | Should -BeFalse
        foreach ($path in $script:originalHashes.Keys) {
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $script:originalHashes[$path]
            Test-Path "$path.e2ebak" | Should -BeFalse
        }
        Should -Invoke Start-Terminal -Times 0
        Should -Invoke Clear-WtConfig -Times 0
    }

    It 'surfaces setup failure, retains owned backups when inactivity is unknown, then recovers after verified inactivity' {
        Mock Start-Terminal {
            Set-WtSettings -App $script:target -Settings $Settings | Out-Null
            throw 'injected launch failure'
        }
        { . $script:setup } | Should -Throw '*injected launch failure*'
        $script:ownsConfig | Should -BeTrue
        Mock Get-WtProcessesForApp { throw 'inactivity discovery denied' }
        { . $script:recovery } | Should -Throw '*inactivity discovery denied*'
        foreach ($path in $script:originalHashes.Keys) {
            (Get-FileHash -LiteralPath "$path.e2ebak").Hash | Should -Be $script:originalHashes[$path]
        }
        Mock Get-WtProcessesForApp { @() }
        . $script:recovery
        foreach ($path in $script:originalHashes.Keys) {
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $script:originalHashes[$path]
        }
        Should -Invoke Clear-WtConfig -Times 0
    }

    It 'refuses recovery while a package process is active and retains owned backups' {
        . $script:setup
        Mock Get-WtProcessesForApp { [pscustomobject]@{ Id = 42 } }
        { . $script:recovery } | Should -Throw '*Dev remains active*'
        foreach ($path in $script:originalHashes.Keys) {
            (Get-FileHash -LiteralPath "$path.e2ebak").Hash | Should -Be $script:originalHashes[$path]
        }
    }
}
}
