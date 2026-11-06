#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.
# Native profile composition crosses settings -> window-targeted event -> ConPTY.
# The fixture has no hooks, ACP connection, history scan or model dependency.
BeforeDiscovery {
    $script:Ready = [bool]$env:ITE2E_PACKAGE
}

Describe 'Feature: native agent profile resume' -Tag @('Feature', 'AgentProfileResume') -Skip:(-not $script:Ready) {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\ItE2E\ItE2E.psd1') -Force
        $script:package = Get-ItTestPackage
        if ($script:package -notlike 'IntelligentTerminal.Worktree.*') {
            throw 'This suite requires an explicit inactive isolated Dev package family.'
        }
        $target = Resolve-ItApp -Package $script:package
        Assert-WtPackageInactive -App $target
        $env:PATH = "$($target.InstallLocation);$env:PATH"
        $env:WT_WTCLI_PATH = $target.WtcliPath
        $env:WTCLI_PATH = $target.WtcliPath
        $env:WT_COM_CLSID = $target.PrivateProtocolClsid
        if (-not $env:ITE2E_EXPECTED_APP_SHA256 -or -not $env:ITE2E_EXPECTED_WTA_SHA256) {
            throw 'Supply exact worktree build payload hashes.'
        }
        (Get-FileHash (Join-Path $target.InstallLocation 'TerminalApp.dll')).Hash | Should -Be $env:ITE2E_EXPECTED_APP_SHA256
        (Get-FileHash $target.WtaPath).Hash | Should -Be $env:ITE2E_EXPECTED_WTA_SHA256
        if (-not $env:ITE2E_AGENT_PROFILE_RESUME_BUILD_RECEIPT) {
            throw 'Supply the isolated build receipt proving private-package-only hook mutation refusal.'
        }
        $receipt = Get-Content -LiteralPath $env:ITE2E_AGENT_PROFILE_RESUME_BUILD_RECEIPT -Raw | ConvertFrom-Json
        $receipt.PackageFamilyName | Should -Be $target.Package
        $receipt.LocalOverrides | Should -Contain 'private-package-only hook mutation refusal'
        $receipt.AppSha256 | Should -Be $env:ITE2E_EXPECTED_APP_SHA256
        $receipt.WtaSha256 | Should -Be $env:ITE2E_EXPECTED_WTA_SHA256
        $script:profile = '{' + [guid]::NewGuid().ToString() + '}'
        $shellProfile = '{' + [guid]::NewGuid().ToString() + '}'
        $script:fixture = (Resolve-Path (Join-Path $PSScriptRoot '..\fixtures\Mock-NativeProfileResume.cmd')).Path
        $script:proofRoot = Join-Path $env:ITE2E_ARTIFACT_ROOT ('native-profile-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:proofRoot -Force | Out-Null
        $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
        $mock = (Resolve-Path (Join-Path $PSScriptRoot '..\fixtures\Mock-AcpInteractionAgent.ps1')).Path
        $mockCode = "& '$($mock.Replace("'", "''"))' -LogPath '$($script:proofRoot.Replace("'", "''"))\acp.log'"
        $mockCommand = "`"$pwsh`" -NoProfile -EncodedCommand " + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($mockCode))
        $script:app = Start-Terminal -Package $script:package -PassFre $true -State @{ sidebarIntroductionShown = $true } -Settings @{
            language = 'en-US'; startupActions = ''; defaultProfile = $shellProfile
            firstWindowPreference = 'defaultProfile'; windowingBehavior = 'useNew'
            autoErrorDetectionEnabled = $false; agentSessionManagementEnabled = $false
            acpAgent = 'custom:pwsh'; acpCustomCommand = $mockCommand
            delegateAgent = 'custom:pwsh'; delegateCustomCommand = $mockCommand
            'warning.confirmOnClose' = 'never'
            acpCustomCommands = @('fixture-adapter.exe --acp --stdio', $mockCommand)
            profiles = @{ defaults = @{ environment = @{
                PATH = "$($target.InstallLocation);$env:PATH"
                WT_WTCLI_PATH = $target.WtcliPath; WTCLI_PATH = $target.WtcliPath
                ITE2E_NATIVE_PROFILE_PROOF_DIR = $script:proofRoot
            } }; list = @(@{
                guid = $script:profile; name = 'Profile resume fixture'
                'agentProfile.id' = 'custom:profile-resume-fixture'
                commandline = "`"$script:fixture`""
                'agentProfile.model' = 'chosen-model'
                'agentProfile.arguments' = '--startup-option'
                'agentProfile.resumeArguments' = '--load-conversation'
                startingDirectory = $env:SystemRoot
                closeOnExit = 'never'
            }, @{
                guid = $shellProfile; name = 'Profile resume shell'
                commandline = "`"$pwsh`" -NoLogo -NoProfile -NoExit"
                shellIntegrationEnabled = $false; closeOnExit = 'never'
            }) }
        }
        $script:app.Launched | Should -BeTrue
        $script:app | Add-Member -NotePropertyName RequireOwnedForeground -NotePropertyValue $true -Force
        $script:listener = Start-WtEventListener -App $script:app -WaitForReady
        function Assert-NativeFixtureTarget([string]$SessionId) {
            $path = Join-Path $script:proofRoot ($SessionId.Trim('{}') + '.json')
            $proof = Wait-Until -TimeoutSec 20 -Because 'the native pane verifies package-local CLI discovery and routing' -Condition {
                if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
            }
            $proof.WtcliPath | Should -Be $script:app.WtcliPath
            $proof.WtaPath | Should -Be $script:app.WtaPath
            $proof.ComClsid.Trim('{}') | Should -Be $script:app.ComClsid.Trim('{}')
            $proof.Query.session_id.Trim('{}') | Should -Be $SessionId.Trim('{}')
            "$($proof.Query.window_id)" | Should -Be "$($script:app.WindowId)"
            $proof.PaneSessionId.Trim('{}') | Should -Be $SessionId.Trim('{}')
        }
        function Select-NativeProfilePage([string]$Name) {
            Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
            if ($script:app.OwnedProcess.HasExited) { throw 'Owned Terminal exited.' }
            $root = [Windows.Automation.AutomationElement]::FromHandle([IntPtr][long]$script:app.Hwnd)
            $root.Current.ProcessId | Should -Be $script:app.Pid
            $nav = $root.FindFirst([Windows.Automation.TreeScope]::Descendants,
                [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, 'SettingsNav'))
            $condition = [Windows.Automation.AndCondition]::new(
                [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, $Name),
                [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ListItem))
            $item = $nav.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
            if (-not $item) { throw "Missing native profile navigation item: $Name" }
            ([Windows.Automation.ScrollItemPattern]$item.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern)).ScrollIntoView()
            $pattern = $null
            if ($item.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
                ([Windows.Automation.InvokePattern]$pattern).Invoke()
            } else {
                ([Windows.Automation.SelectionItemPattern]$item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)).Select()
            }
        }
        function Get-NativeMasterSessions {
            $master = Get-WtaMasterPipe -App $script:app
            $snapshot = Invoke-Wta -App $script:app -Arguments @('sessions', 'list', '--json',
                '--master', $master, '--include-status', '--origin', 'all')
            [IO.File]::WriteAllText((Join-Path $script:proofRoot 'master-snapshot.json'), ($snapshot | ConvertTo-Json -Depth 20))
            $snapshot.sessions
        }
    }

    AfterAll {
        if ($script:listener) {
            [IO.File]::WriteAllText((Join-Path $script:proofRoot 'events.json'), (@(Get-WtEvents -Listener $script:listener) | ConvertTo-Json -Depth 20))
        }
        if ($script:listener) { Stop-WtEventListener -Listener $script:listener }
        if ($script:app) { Stop-Terminal -App $script:app }
    }

    It 'Native profile resume uses effective launch and resume arguments only when requested' {
        foreach ($tracking in @($false, $true)) {
            Set-WtSetting -App $script:app -Key agentSessionManagementEnabled -Value $tracking | Out-Null
            $ordinary = Invoke-WtCli -App $script:app -Arguments @(
                'new-tab', '-p', $script:profile, '--window-id', "$($script:app.WindowId)"
            )
            $text = Wait-Until -TimeoutSec 20 -Because 'ordinary profile fixture starts' -Condition {
                $capture = Get-WtCapture -App $script:app -SessionId $ordinary.session_id
                if ($capture -match 'PROFILE-RESUME-ARGS') { $capture }
            }
            $text | Should -Match '--model.*chosen-model.*--startup-option'
            $text | Should -Not -Match '--load-conversation'
            Assert-NativeFixtureTarget $ordinary.session_id
            $knownId = 'fixture-' + [guid]::NewGuid().ToString('N')
            $requestId = [guid]::NewGuid().ToString()
            $request = @{
                window_id = "$($script:app.WindowId)"; agent_id = 'custom:profile-resume-fixture'
                agent_source = 'host'; resume_target = 'native'
                profile_id = $script:profile; session_id = $knownId
                request_id = $requestId
            } | ConvertTo-Json -Compress
            $event = @{ type = 'event'; method = 'resume_in_new_agent_tab'; params = ($request | ConvertFrom-Json) } | ConvertTo-Json -Compress
            Invoke-WtCli -App $script:app -Arguments @('publish', '--existing-only', $event) | Out-Null
            $receipt = Wait-WtEvent -Listener $script:listener -TimeoutSec 20 -Predicate {
                $_.method -eq 'native_profile_resume_result' -and $_.params.request_id -eq $requestId
            }
            $receipt.params.success | Should -BeTrue
            $resumed = [pscustomobject]@{ session_id = $receipt.params.result.session_id }
            $resumed.session_id | Should -Not -BeNullOrEmpty
            $text = Wait-Until -TimeoutSec 20 -Because 'resumed fixture receives the effective arguments and automatic ID' -Condition {
                $capture = Get-WtCapture -App $script:app -SessionId $resumed.session_id
                if ($capture -match [regex]::Escape($knownId)) { $capture }
            }
            $text | Should -Match "--model.*chosen-model.*--startup-option.*--load-conversation.*$knownId"
            $text | Should -Not -Match '--acp|--stdio'
            Assert-NativeFixtureTarget $resumed.session_id
            $receipt.params.result.session_id.Trim('{}') | Should -Be $resumed.session_id.Trim('{}')

            $panes = @(Get-WtPanes -App $script:app)
            $panes.Count | Should -BeGreaterThan 0
            $count = $panes.Count
            $rejectedId = [guid]::NewGuid().ToString()
            $mismatch = @{
                window_id = "$($script:app.WindowId)"; agent_id = 'custom:wrong-provider'
                agent_source = 'host'; resume_target = 'native'; profile_id = $script:profile
                session_id = $knownId; request_id = $rejectedId
            } | ConvertTo-Json -Compress
            $event = @{ type = 'event'; method = 'resume_in_new_agent_tab'; params = ($mismatch | ConvertFrom-Json) } | ConvertTo-Json -Compress
            Invoke-WtCli -App $script:app -Arguments @('publish', '--existing-only', $event) | Out-Null
            $rejected = Wait-WtEvent -Listener $script:listener -TimeoutSec 20 -Predicate {
                $_.method -eq 'native_profile_resume_result' -and $_.params.request_id -eq $rejectedId
            }
            $rejected.params.success | Should -BeFalse
            @(Get-WtPanes -App $script:app).Count | Should -Be $count
        }
    }

    It 'Master native history activation uses edited profile settings and preserves its receipt' {
        Set-WtSetting -App $script:app -Key agentSessionManagementEnabled -Value $true | Out-Null
        $provider = 'custom:fixture-adapter'
        $generated = @((Invoke-WtCli -App $script:app -Arguments @('list-profiles')).profiles |
            Where-Object agent_id -EQ $provider) | Select-Object -First 1
        $generated | Should -Not -BeNullOrEmpty
        $guid = '{' + ([string]$generated.id).Trim('{}') + '}'
        $settings = Get-WtSettingsObject -App $script:app
        $others = @($settings.profiles.list | Where-Object { ([string]$_.guid).Trim('{}') -ne $guid.Trim('{}') })
        $profile = @{
            guid = $guid; source = 'IntelligentTerminal.AgentProfiles'; name = 'fixture-adapter configured'
            commandline = "`"$script:fixture`""; 'agentProfile.model' = 'master-model'
            'agentProfile.arguments' = '--master-startup'; 'agentProfile.resumeArguments' = '--load-master'
            startingDirectory = $env:SystemRoot; closeOnExit = 'never'
        }
        $settings.profiles.list = $others + @($profile)
        Set-WtSetting -App $script:app -Key profiles -Value $settings.profiles | Out-Null
        Wait-Until -TimeoutSec 15 -Because 'the generated original receives its independent native command' -Condition {
            @((Invoke-WtCli -App $script:app -Arguments @('list-profiles')).profiles |
                Where-Object { $_.name -eq 'fixture-adapter configured' }).Count -eq 1
        } | Out-Null
        $knownId = 'master-fixture-' + [guid]::NewGuid().ToString('N')
        $requestId = [guid]::NewGuid().ToString()
        $event = @{ type = 'event'; method = 'resume_in_new_agent_tab'; params = @{
            window_id = "$($script:app.WindowId)"; agent_id = $provider; agent_source = 'host'
            resume_target = 'native'; profile_id = $guid; session_id = $knownId; request_id = $requestId
        } } | ConvertTo-Json -Compress -Depth 6
        Invoke-WtCli -App $script:app -Arguments @('publish', '--existing-only', $event) | Out-Null
        $seed = Wait-WtEvent -Listener $script:listener -TimeoutSec 20 -Predicate {
            $_.method -eq 'native_profile_resume_result' -and $_.params.request_id -eq $requestId
        }
        $seed.params.success | Should -BeTrue
        Assert-NativeFixtureTarget $seed.params.result.session_id
        Wait-Until -TimeoutSec 20 -Because 'the actual native pane binding reaches the owning master' -Condition {
            @(Get-NativeMasterSessions | Where-Object session_id -EQ $knownId).Count -eq 1
        } | Out-Null
        Close-WtPane -App $script:app -SessionId $seed.params.result.session_id
        Wait-Until -TimeoutSec 20 -Because 'closing the fixture leaves an unbound resumable history row' -Condition {
            $row = @(Get-NativeMasterSessions | Where-Object session_id -EQ $knownId) | Select-Object -First 1
            $row -and -not $row.pane_session_id
        } | Out-Null
        $profile.name = 'fixture-adapter'
        $profile['agentProfile.model'] = 'edited-model'
        $profile['agentProfile.resumeArguments'] = '--load-edited-master'
        $settings.profiles.list = $others + @($profile)
        Set-WtSetting -App $script:app -Key profiles -Value $settings.profiles | Out-Null
        Wait-Until -TimeoutSec 15 -Because 'resume reads the newly edited profile rather than its old launch' -Condition {
            @((Invoke-WtCli -App $script:app -Arguments @('list-profiles')).profiles |
                Where-Object { $_.name -eq 'fixture-adapter' }).Count -eq 1
        } | Out-Null
        $pipe = Get-WtaMasterPipe -App $script:app
        $activation = [guid]::NewGuid().ToString()
        $arguments = @('sessions', 'activate', '--json', '--master', $pipe, '--session-id', $knownId,
            '--provider', $provider, '--location', 'host', '--window-id', "$($script:app.WindowId)", '--activation-id', $activation)
        $receipt = Invoke-Wta -App $script:app -Arguments $arguments
        $receipt.accepted | Should -BeTrue
        $receipt.launched | Should -BeTrue
        $pane = Get-ActivePane -App $script:app
        $pane.session_id.Trim('{}') | Should -Not -Be $seed.params.result.session_id.Trim('{}')
        Assert-NativeFixtureTarget $pane.session_id
        $text = Get-WtCapture -App $script:app -SessionId $pane.session_id
        $text | Should -Match "--model.*edited-model.*--master-startup.*--load-edited-master.*$knownId"
        $text | Should -Not -Match '--load-master'
        $replay = Invoke-Wta -App $script:app -Arguments $arguments
        $replay | ConvertTo-Json -Depth 8 -Compress | Should -Be ($receipt | ConvertTo-Json -Depth 8 -Compress)
        (Get-ActivePane -App $script:app).session_id | Should -Be $pane.session_id
    }

    It 'Agent profile settings expose an indicator and automatic session ID guidance' {
        Open-WtSettings -App $script:app | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:proofRoot 'settings-navigation.txt'), (Get-UiTree -App $script:app -Depth 20))
        Select-NativeProfilePage 'Profile resume fixture'
        Test-UiElementExists -App $script:app -Selector 'Agent profile' -TimeoutSec 10 | Should -BeTrue
        Test-UiElementExists -App $script:app -Selector 'Resume arguments' -TimeoutSec 10 | Should -BeTrue
        $tree = Get-UiTree -App $script:app -Depth 15
        Test-UiElementExists -App $script:app -Selector 'Added after the normal startup arguments only when resuming a session. The session ID is appended automatically.' -TimeoutSec 10 | Should -BeTrue
        $tree | Should -Match 'Delete profile'
        $original = @((Invoke-WtCli -App $script:app -Arguments @('list-profiles')).profiles |
            Where-Object agent_id -EQ 'custom:fixture-adapter') | Select-Object -First 1
        Select-NativeProfilePage $original.name
        $generated = Get-UiTree -App $script:app -Depth 15
        $generated | Should -Match 'Agent profile'
        $generated | Should -Not -Match 'Delete profile'
        $generated | Should -Match 'Appearance'
    }
}
