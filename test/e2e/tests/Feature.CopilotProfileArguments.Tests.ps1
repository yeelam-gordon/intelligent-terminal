#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
# Real native profile -> launch validation -> ConPTY -> installed Copilot.
# --version exits without a prompt or session; no unrestricted model work is submitted.

Describe 'Feature: Copilot profile arguments' -Tag @('Feature', 'CopilotProfileArguments') {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\ItE2E\ItE2E.psd1') -Force
        $script:app = $null
        $script:copilotHomeOwned = $false
        if ($env:ITE2E_PACKAGE -notlike 'IntelligentTerminal.Worktree.*_rd9vj3e6a2mbr') {
            throw 'Select an explicit inactive private Dev worktree package.'
        }
        $script:target = Resolve-ItApp -Package $env:ITE2E_PACKAGE
        Assert-WtPackageInactive -App $script:target
        $head = (& git -C (Join-Path $PSScriptRoot '..\..\..') rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or $env:ITE2E_SOURCE_COMMIT -ne $head) {
            throw 'Supply the exact source commit from the tested build.'
        }
        foreach ($entry in @(
            @{ Path = (Join-Path $script:target.InstallLocation 'TerminalApp.dll'); Hash = $env:ITE2E_EXPECTED_APP_SHA256 },
            @{ Path = $script:target.WtaPath; Hash = $env:ITE2E_EXPECTED_WTA_SHA256 }
        )) {
            if (-not $entry.Hash -or (Get-FileHash -LiteralPath $entry.Path).Hash -ne $entry.Hash) {
                throw 'Installed payload does not match the candidate build receipt.'
            }
        }
        $script:automationHome = Join-Path $env:LOCALAPPDATA 'CopilotAutomation'
        # The host's prewarmed WTA helpers also need the automation home, not just
        # the native profile process. This changes only this test runner's environment.
        $script:previousCopilotHome = $env:COPILOT_HOME
        $env:COPILOT_HOME = $script:automationHome
        $script:copilotHomeOwned = $true
        $script:runId = [guid]::NewGuid().ToString('N')
        $script:cwd = Join-Path $env:ITE2E_ARTIFACT_ROOT "auto-profile-args-$script:runId"
        New-Item -ItemType Directory -Force -Path $script:cwd | Out-Null
        function Start-CopilotArgumentProfile {
            param([string]$Arguments, [string]$PermissionMode = '')
            $profileId = '{b22d61a8-5509-4694-82fc-263214f54fb3}'
            $script:app = Start-Terminal -Package $env:ITE2E_PACKAGE -PassFre $true -Settings @{
                defaultProfile = $profileId
                firstWindowPreference = 'defaultProfile'; startupActions = ''
                windowingBehavior = 'useNew'; tabLayout = 'horizontal'
                agentSessionManagementEnabled = $false
                autoErrorDetectionEnabled = $false; autoFixEnabled = $false
                'warning.confirmOnClose' = 'never'
                profiles = @{ list = @(@{
                    guid = $profileId; name = "auto:test:copilot-profile-args:$script:runId"
                    'agentProfile.id' = 'copilot'
                    'agentProfile.arguments' = $Arguments
                    'agentProfile.permissionMode' = $PermissionMode
                    startingDirectory = $script:cwd; closeOnExit = 'never'
                    environment = @{
                        COPILOT_HOME = $script:automationHome
                        PATH = "$($script:target.InstallLocation);$env:PATH"
                        WT_WTCLI_PATH = $script:target.WtcliPath
                        WTCLI_PATH = $script:target.WtcliPath
                    }
                }) }
            }
            Get-ActivePane -App $script:app
        }
    }

    AfterEach {
        if ($script:app) {
            Stop-Terminal -App $script:app
            $script:app = $null
        }
    }

    AfterAll {
        if ($script:copilotHomeOwned) {
            $env:COPILOT_HOME = $script:previousCopilotHome
        }
    }

    It 'Copilot profile yolo arguments launch the native CLI' {
        $pane = Start-CopilotArgumentProfile -Arguments '--yolo --version'
        Wait-Until -TimeoutSec 30 -Because 'the real Copilot version reaches the managed profile buffer' -Condition {
            (Get-WtCapture -App $script:app -SessionId $pane.session_id) -match '(?m)^GitHub Copilot CLI \S+'
        } | Out-Null
        $text = Get-WtCapture -App $script:app -SessionId $pane.session_id
        $text | Should -Not -Match '0x80070057|Unsupported or conflicting native agent argument'
        Wait-WtPaneExit -App $script:app -SessionId $pane.session_id
        # NativePath regenerates PATH; the app can resolve a different installed CLI
        # than the runner. Assert its output and ConPTY's exit footer, not runner version.
        (Get-WtPaneStatus -App $script:app -SessionId $pane.session_id).state | Should -Be 'exited'
        (Get-WtCapture -App $script:app -SessionId $pane.session_id) |
            Should -Match '\[process exited with code 0 \(0x00000000\)\]'
    }

    It 'Copilot profile unsupported and conflicting arguments fail before launch' {
        foreach ($case in @(
            @{ Arguments = '--unsupported-native-argument'; Mode = '' },
            @{ Arguments = '--yolo --version'; Mode = 'allow-all-tools' }
        )) {
            $pane = Start-CopilotArgumentProfile -Arguments $case.Arguments -PermissionMode $case.Mode
            Wait-Until -TimeoutSec 15 -Because 'Terminal displays the managed argument rejection' -Condition {
                (Get-WtCapture -App $script:app -SessionId $pane.session_id).Contains('Unsupported or conflicting native agent argument')
            } | Out-Null
            (Get-WtCapture -App $script:app -SessionId $pane.session_id) | Should -Match '0x80070057'
            (Get-WtPaneStatus -App $script:app -SessionId $pane.session_id).pid | Should -Be 0
            Stop-Terminal -App $script:app
            $script:app = $null
        }
    }
}
