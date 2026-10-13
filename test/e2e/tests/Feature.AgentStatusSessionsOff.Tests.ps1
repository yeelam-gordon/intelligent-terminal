#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
# Real provider-labelled COM creation -> child stdout -> ConPTY parser -> Sidebar metadata.
# No hooks, ACP prompts, status injection or inferred conversation IDs. Resume binding,
# effective-policy overrides and pane-removal cleanup require native unit proof.
# Without Sessions/hooks, command completion or retained connection state cannot
# prove that the native agent ended; its pane ID must disappear.
Describe 'Feature: native agent status with Sessions off' -Tag @('Feature', 'AgentStatusSessionsOff') {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\ItE2E\ItE2E.psd1') -Force
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        $script:app = $null
        $script:ownsConfig = $false
        $script:suiteClock = [Diagnostics.Stopwatch]::StartNew()
        $script:fixtures = @()
        $script:runnerEnvironment = @{}
        $script:hookIsolationVerified = $false
        if (-not $env:ITE2E_PACKAGE -or $env:ITE2E_PACKAGE -in @('Auto', 'Dev', 'Store')) {
            throw 'Pin the owned isolated Dev package family; ordinary Dev and Store are forbidden.'
        }
        $script:target = Resolve-ItApp -Package $env:ITE2E_PACKAGE
        if (@(Get-WtProcessesForApp -App $script:target -IncludePackageExecutables).Count) {
            throw 'The selected private package must be inactive; never adopt or close existing hosts.'
        }
        $head = (& git -C (Join-Path $PSScriptRoot '..\..\..') rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or $env:ITE2E_SOURCE_COMMIT -ne $head) {
            throw 'Supply ITE2E_SOURCE_COMMIT from the exact feature-head build receipt.'
        }
        foreach ($entry in @(
            @{ Path = (Join-Path $script:target.InstallLocation 'TerminalApp.dll'); Hash = $env:ITE2E_EXPECTED_APP_SHA256 },
            @{ Path = $script:target.WtaPath; Hash = $env:ITE2E_EXPECTED_WTA_SHA256 }
        )) {
            if (-not $entry.Hash) { throw 'Supply exact-source deployed App and WTA SHA256 receipts.' }
            (Get-FileHash -LiteralPath $entry.Path).Hash | Should -Be $entry.Hash
        }
        $script:originalHashes = @{}
        foreach ($path in @($script:target.SettingsPath, $script:target.StatePath)) {
            if ((Test-Path "$path.e2ebak") -or (Test-Path "$path.e2ebak.missing")) {
                throw "Recover existing backup before testing: $path"
            }
            $script:originalHashes[$path] = if (Test-Path $path) { (Get-FileHash $path).Hash } else { $null }
        }
        $root = if ($env:ITE2E_ARTIFACT_ROOT) { $env:ITE2E_ARTIFACT_ROOT } else { Join-Path $PSScriptRoot '..\artifacts' }
        $script:evidence = Join-Path ([IO.Path]::GetFullPath($root)) ('sessions-off-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:evidence | Out-Null
        $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
        $script:wrapperDir = Join-Path $script:evidence 'hook-cli-wrappers'
        New-Item -ItemType Directory -Path $script:wrapperDir | Out-Null
        $script:providers = @('copilot', 'claude', 'codex', 'gemini', 'opencode')
        foreach ($provider in $script:providers) {
            $receipt = Join-Path $script:evidence "$provider-wrapper.log"
            @("@echo off", ">>`"$receipt`" echo $provider fixture invoked", 'exit /b 1') |
                Set-Content (Join-Path $script:wrapperDir "$provider.cmd") -Encoding ascii
        }
        $automationHome = Join-Path $script:evidence 'automation-home'
        $script:isolatedEnvironment = @{
            USERPROFILE = $automationHome; HOME = $automationHome
            XDG_CONFIG_HOME = (Join-Path $automationHome '.config')
            COPILOT_HOME = (Join-Path $automationHome '.copilot')
            CLAUDE_CONFIG_DIR = (Join-Path $automationHome '.claude')
            CODEX_HOME = (Join-Path $automationHome '.codex')
            GEMINI_CLI_HOME = (Join-Path $automationHome '.gemini')
            OPENCODE_CONFIG_DIR = (Join-Path $automationHome '.config\opencode')
            PATH = "$script:wrapperDir;$($script:target.InstallLocation);$env:PATH"
            WT_WTCLI_PATH = $script:target.WtcliPath; WTCLI_PATH = $script:target.WtcliPath
        }
        foreach ($key in $script:isolatedEnvironment.Keys) {
            $script:runnerEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
            [Environment]::SetEnvironmentVariable($key, $script:isolatedEnvironment[$key], 'Process')
        }
        foreach ($key in @('USERPROFILE', 'HOME', 'XDG_CONFIG_HOME', 'COPILOT_HOME', 'CLAUDE_CONFIG_DIR',
            'CODEX_HOME', 'GEMINI_CLI_HOME', 'OPENCODE_CONFIG_DIR')) {
            New-Item -ItemType Directory -Path $script:isolatedEnvironment[$key] -Force | Out-Null
        }
        # Unredirected known-folder queries expand USERPROFILE, whereas packaged
        # settings stay in the registered user's LocalState.
        New-Item -ItemType Directory -Path (Join-Path $automationHome 'AppData\Local'),
            (Join-Path $automationHome 'AppData\Roaming') -Force | Out-Null
        $script:fixture = Join-Path $script:evidence 'Emit-NativeStatus.ps1'
        @'
param([string]$Signal, [string]$Receipt, [string]$Title, [int]$LifetimeSec = 300)
[Console]::Write([char]27 + ']0;' + $Title + [char]27 + '\')
$last = ''
$clock = [Diagnostics.Stopwatch]::StartNew()
while ($clock.Elapsed.TotalSeconds -lt $LifetimeSec) {
    if (Test-Path -LiteralPath $Signal) {
        $line = Get-Content -LiteralPath $Signal -Raw
        if ($line -and $line -ne $last) {
            $last = $line
            $request = $line | ConvertFrom-Json
            if ($request.kind -eq 'close') { exit 0 }
            if ($request.kind -eq 'bell') { [Console]::Write([char]7) }
            else { [Console]::Write([char]27 + ']9;4;' + $request.state + ';50' + [char]27 + '\') }
            [Console]::Out.Flush()
            [IO.File]::WriteAllText($Receipt, $request.token)
        }
    }
    Start-Sleep -Milliseconds 50
}
@{ status = 'timed-out'; pid = $PID; lifetime_seconds = $LifetimeSec } |
    ConvertTo-Json | Set-Content -LiteralPath "$Receipt.failure.json"
exit 124
'@ | Set-Content -LiteralPath $script:fixture
        $acp = (Resolve-Path (Join-Path $PSScriptRoot '..\fixtures\Mock-AcpChatAgent.ps1')).Path
        $history = Join-Path $script:evidence 'acp-history.json'
        @{ sessions = @() } | ConvertTo-Json | Set-Content -LiteralPath $history
        $code = "& '$($acp.Replace("'", "''"))' -LogPath '$($script:evidence.Replace("'", "''"))\acp.log' -HistoryPath '$($history.Replace("'", "''"))'"
        $profile = '{' + [guid]::NewGuid().ToString() + '}'
        $script:ownsConfig = $true
        $script:app = Start-Terminal -Package $env:ITE2E_PACKAGE -PassFre $true -State @{
            sidebarLayoutMigrationCompleted = $true; sidebarIntroductionShown = $true
        } -Settings @{
            language = 'en-US'; tabLayout = 'vertical'; startupActions = ''
            firstWindowPreference = 'defaultProfile'; windowingBehavior = 'useNew'
            agentSessionManagementEnabled = $false; autoErrorDetectionEnabled = $false; autoFixEnabled = $false
            acpAgent = 'custom:sessions-off-fixture'
            acpCustomCommand = 'pwsh -NoProfile -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
            'warning.confirmOnClose' = 'never'; defaultProfile = $profile
            profiles = @{ list = @(@{
                guid = $profile; name = 'Sessions-off control'; commandline = "`"$pwsh`" -NoLogo -NoProfile -NoExit"
                tabTitle = 'Sessions-off control'; suppressApplicationTitle = $true
                shellIntegrationEnabled = $false
                reloadEnvironmentVariables = $false
                environment = $script:isolatedEnvironment
            }) }
        }
        $script:app.Launched | Should -BeTrue
        $script:window = [string]$script:app.WindowId
        $settingsReadByHost = Invoke-WtCli -App $script:app -Arguments @('get-settings')
        $settingsReadByHost.defaultProfile | Should -Be $profile
        $settingsReadByHost.agentSessionManagementEnabled | Should -BeFalse
        $initialTabs = @(Get-WtTabs -App $script:app -WindowId $script:window)
        $initialTabs | Should -HaveCount 1
        $initialTabs[0].title | Should -Be 'Sessions-off control' -Because 'the actual host must load the fixture profile, not fallback defaults'
        $settingsReadByHost | ConvertTo-Json -Depth 12 |
            Set-Content (Join-Path $script:evidence 'settings-read-by-host.json')
        # Profile overrides prove pane-side isolation separately. They cannot
        # prove the host environment used for C++ hook reconciliation.
        $probeFile = Join-Path $script:evidence 'host-hook-isolation.json'
        $probeCode = @"
try {
`$names = @('copilot', 'claude', 'codex', 'gemini', 'opencode')
`$envNames = @('USERPROFILE', 'HOME', 'XDG_CONFIG_HOME', 'COPILOT_HOME', 'CLAUDE_CONFIG_DIR',
    'CODEX_HOME', 'GEMINI_CLI_HOME', 'OPENCODE_CONFIG_DIR', 'PATH')
`$environment = @{}
foreach (`$name in `$envNames) { `$environment[`$name] = [Environment]::GetEnvironmentVariable(`$name, 'Process') }
`$paths = @{}
foreach (`$name in `$names) {
    `$paths[`$name] = (Get-Command `$name -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    & `$paths[`$name] --version 2>`$null | Out-Null
}
`$statusText = & '$($script:target.WtaPath.Replace("'", "''"))' hooks status --json
if (`$LASTEXITCODE -ne 0) { throw 'Read-only hook status probe failed' }
@{ environment = `$environment; paths = `$paths; hook_status = (`$statusText -join "`n" | ConvertFrom-Json) } |
    ConvertTo-Json -Depth 12 | Set-Content -LiteralPath '$($probeFile.Replace("'", "''"))'
}
catch {
    @{ error = `$_.ToString(); stack = `$_.ScriptStackTrace; environment = `$environment; paths = `$paths } | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath '$($probeFile.Replace("'", "''")).failure.json'
    throw
}
"@
        $probeCode | Set-Content (Join-Path $script:evidence 'host-hook-isolation-probe.ps1')
        $probeTokens = $null
        $probeErrors = $null
        [void][Management.Automation.Language.Parser]::ParseInput($probeCode, [ref]$probeTokens, [ref]$probeErrors)
        if ($probeErrors.Count) { throw ($probeErrors.Message -join '; ') }
        $probeEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeCode))
        $probePane = New-WtTab -App $script:app -Command "`"$pwsh`" -NoProfile -NoExit -EncodedCommand $probeEncoded"
        try {
            Wait-Until -TimeoutSec 30 -Because 'owned host inheritance and read-only hook resolver proof' -Condition {
                (Test-Path -LiteralPath $probeFile) -or (Test-Path -LiteralPath "$probeFile.failure.json")
            } | Out-Null
            if (Test-Path -LiteralPath "$probeFile.failure.json") {
                throw (Get-Content -LiteralPath "$probeFile.failure.json" -Raw)
            }
        }
        finally {
            Get-WtCapture -App $script:app -SessionId $probePane.session_id -MaxLines 100 |
                Set-Content (Join-Path $script:evidence 'host-hook-isolation-probe.txt')
        }
        $probe = Get-Content -LiteralPath $probeFile -Raw | ConvertFrom-Json
        foreach ($key in @('USERPROFILE', 'HOME', 'XDG_CONFIG_HOME', 'COPILOT_HOME', 'CLAUDE_CONFIG_DIR',
            'CODEX_HOME', 'GEMINI_CLI_HOME', 'OPENCODE_CONFIG_DIR')) {
            $probe.environment.$key | Should -Be $script:isolatedEnvironment[$key]
        }
        ($probe.environment.PATH -split ';') | Should -Contain $script:wrapperDir
        foreach ($provider in $script:providers) {
            $expected = Join-Path $script:wrapperDir "$provider.cmd"
            $probe.paths.$provider | Should -Be $expected
            $cli = @($probe.hook_status.clis | Where-Object name -EQ $provider)
            $cli | Should -HaveCount 1
            $cli[0].binary_path | Should -Be $expected
            $cli[0].plugin_installed | Should -BeFalse
            (Test-Path (Join-Path $script:evidence "$provider-wrapper.log")) | Should -BeTrue
        }
        $creator = $script:app.OwnedLauncherProcess
        $directHost = $creator -and -not $creator.HasExited -and
            $creator.Id -eq $script:app.Pid -and
            $creator.Path -eq (Join-Path $script:target.InstallLocation 'WindowsTerminal.exe') -and
            $creator.StartTime -eq $script:app.OwnedProcess.StartTime
        # The verified wtai creator launches its adjacent host with a null
        # environment block (src/cascadia/wt/shim.cpp), preserving inheritance.
        $shimHost = $creator -and
            $script:app.PSObject.Properties.Name -contains 'CreatedTerminalParentPid' -and
            $script:app.CreatedTerminalParentPid -eq $creator.Id -and
            $script:app.OwnedProcess.Path -eq (Join-Path $script:target.InstallLocation 'WindowsTerminal.exe')
        @{
            pane_isolation_verified = $true
            direct_inherited_host_verified = [bool]$directHost
            shim_inherited_host_verified = [bool]$shimHost
            created_pid = if ($creator) { $creator.Id } else { $null }
            actual_host_pid = $script:app.Pid
            required_image = (Join-Path $script:target.InstallLocation 'WindowsTerminal.exe')
            reason = 'Direct creation or the identity-verified wtai creator chain preserves the isolated runner environment.'
        } | ConvertTo-Json | Set-Content (Join-Path $script:evidence 'host-activation-isolation.json')
        $script:hookIsolationVerified = [bool]($directHost -or $shimHost)
        function Assert-StatusDeadline {
            if ($script:suiteClock.Elapsed.TotalSeconds -ge 240) {
                throw 'Sessions-off suite exceeded its four-minute outer deadline.'
            }
            foreach ($fixture in $script:fixtures) {
                if (Test-Path "$($fixture.Receipt).failure.json") {
                    throw "Native fixture timed out: $($fixture.Receipt).failure.json"
                }
            }
        }
        function New-StatusFixture {
            param([string]$Kind)
            Assert-StatusDeadline
            $title = "IT-status-$Kind-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $signal = Join-Path $script:evidence "$title.signal.json"
            $receipt = Join-Path $script:evidence "$title.receipt.txt"
            $command = "`"$pwsh`" -NoProfile -File `"$script:fixture`" -Signal `"$signal`" -Receipt `"$receipt`" -Title $title"
            $args = @('new-tab', '-c', $command, '-n', $title, '-d', $script:evidence)
            if ($Kind -eq 'native') { $args += @('--agent-provider', 'copilot') }
            $pane = Invoke-WtCli -App $script:app -Arguments $args
            $pane.session_id | Should -Not -BeNullOrEmpty
            $fixture = [pscustomobject]@{ Pane = $pane; Title = $title; Signal = $signal; Receipt = $receipt; Kind = $Kind }
            $script:fixtures += $fixture
            $fixture
        }
        function Get-StatusText {
            param($Fixture)
            Assert-StatusDeadline
            $root = [Windows.Automation.AutomationElement]::FromHandle([IntPtr][long]$script:app.Hwnd)
            $root.Current.ProcessId | Should -Be $script:app.Pid
            $list = $root.FindFirst([Windows.Automation.TreeScope]::Descendants,
                [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, 'ItemsList'))
            if (-not $list -or $list.Current.IsOffscreen) { throw 'Owned Sidebar ItemsList is not visible.' }
            $rows = @($list.FindAll([Windows.Automation.TreeScope]::Children,
                [Windows.Automation.Condition]::TrueCondition) | Where-Object {
                -not $_.Current.IsOffscreen -and $_.Current.Name.Contains($Fixture.Title)
            })
            if ($rows.Count -ne 1) { return $null }
            # The top-level tab peer contains first-party metadata. Descendant
            # progress-ring peers also say Error/Paused for ordinary shells.
            $rows[0].Current.Name
        }
        function Send-StatusSignal {
            param($Fixture, [string]$Kind = 'progress', [int]$State = 0)
            if ($Kind -ne 'close') { Assert-StatusDeadline }
            $token = [guid]::NewGuid().ToString('N')
            $request = @{ kind = $Kind; state = $State; token = $token } | ConvertTo-Json -Compress
            $staging = "$($Fixture.Signal).next"
            [IO.File]::WriteAllText($staging, $request)
            Move-Item -LiteralPath $staging -Destination $Fixture.Signal -Force
            if ($Kind -ne 'close') {
                Wait-Until -TimeoutSec 10 -Because 'the real child emitted the exact signal' -Condition {
                    Assert-StatusDeadline
                    (Test-Path $Fixture.Receipt) -and (Get-Content $Fixture.Receipt -Raw) -eq $token
                } | Out-Null
            }
        }
        function Assert-Status {
            param($Fixture, [string]$Expected)
            $text = Wait-Until -TimeoutSec 10 -Because "native metadata reaches $Expected" -Condition {
                $value = Get-StatusText $Fixture
                if ($value -match "(?m)(^|[ ,·])$([regex]::Escape($Expected))($|[ ,·])") { $value }
            }
            $text | Should -Not -Match 'Waiting for input'
            $text | Set-Content (Join-Path $script:evidence "$($Fixture.Title)-$Expected.txt")
        }
        function Assert-NoAgentStatus {
            param($Fixture)
            $deadline = [DateTime]::UtcNow.AddSeconds(2)
            do {
                $text = Get-StatusText $Fixture
                $text | Should -Not -BeNullOrEmpty -Because 'suppression requires a realized owned row'
                $text | Should -Not -Match '(?m)(^|[ ,·])(Active|Idle|Error|Paused|Attention requested|Waiting for input)($|[ ,·])'
                Start-Sleep -Milliseconds 100
            } while ([DateTime]::UtcNow -lt $deadline)
        }
        function Assert-NoFabricatedBinding {
            param($Fixture)
            Assert-StatusDeadline
            $pipe = (Get-Content (Join-Path $script:app.LocalStateDir 'IntelligentTerminal\master-pipe.txt') -Raw).Trim()
            $pipe | Should -Not -BeNullOrEmpty
            # --include-status returns SessionsListResponse, not default JSON-lines.
            $result = Invoke-Wta -App $script:app -TimeoutSec 10 -Raw -Arguments @(
                'sessions', 'list', '--master', $pipe, '--json', '--include-status', '--origin', 'all')
            $result.ExitCode | Should -Be 0 -Because $result.StdErr
            $result.StdOut | Should -Not -BeNullOrEmpty
            $snapshot = ConvertFrom-Json -InputObject $result.StdOut -NoEnumerate -ErrorAction Stop
            $snapshot | Should -BeOfType [pscustomobject]
            $snapshot.PSObject.Properties.Name | Should -Contain sessions
            $snapshot.PSObject.Properties.Name | Should -Contain history_status
            ($snapshot.sessions -is [array]) | Should -BeTrue -Because 'including an empty sessions array is mandatory'
            # History discovery failures are independent of this successful
            # full-registry response; they do not invalidate live pane bindings.
            $snapshot.history_status | Should -BeIn @('loading', 'ready', 'error')
            (Get-Content (Join-Path $script:evidence 'acp.log') -Raw) | Should -Match '(?m)^\d+\|list\|' -Because 'the fixture must exercise real ACP session discovery'
            foreach ($session in $snapshot.sessions) {
                $session.PSObject.Properties.Name | Should -Contain session_id
                $session.PSObject.Properties.Name | Should -Contain pane_session_id
                $session.session_id | Should -Not -BeNullOrEmpty
            }
            $result.StdOut | Set-Content (Join-Path $script:evidence "$($Fixture.Title)-binding.json")
            @($snapshot.sessions | Where-Object pane_session_id -EQ $Fixture.Pane.session_id) | Should -HaveCount 0
        }
        $script:native = New-StatusFixture native
        $script:otherNative = New-StatusFixture native
        $script:shell = New-StatusFixture shell
        foreach ($fixture in $script:fixtures) {
            Wait-Until -TimeoutSec 15 -Because 'the real fixture row has its unique title' -Condition {
                Get-StatusText $fixture
            } | Out-Null
        }
        foreach ($fixture in @($script:native, $script:otherNative)) {
            $panes = @(Get-WtPanes -App $script:app -WindowId $script:window -TabId $fixture.Pane.tab_id)
            ($panes | Where-Object session_id -EQ $fixture.Pane.session_id).native_agent_provider_id | Should -Be copilot
        }
    }
    AfterAll {
        try {
        if ($script:app) {
            $owned = $script:app.OwnedProcess
            if (-not $script:app.Launched -or -not $owned -or $owned.Id -ne $script:app.Pid) {
                throw 'Cleanup lacks owned host receipt; retain backups.'
            }
            try {
                foreach ($fixture in $script:fixtures) {
                    Send-StatusSignal $fixture -Kind close
                }
            }
            finally {
                # Existing harness enforces run/PID/path/start receipts, finite
                # graceful close then exact-owned fallback and inactive restore.
                Stop-Terminal -App $script:app -GraceSec 8
            }
        }
        elseif ($script:ownsConfig -and $script:target -and
            -not @(Get-WtProcessesForApp -App $script:target -IncludePackageExecutables).Count) {
            Restore-WtConfig -App $script:target
        }
        if ($script:ownsConfig -and -not @(Get-WtProcessesForApp -App $script:target -IncludePackageExecutables).Count) {
            foreach ($path in $script:originalHashes.Keys) {
                $actual = if (Test-Path $path) { (Get-FileHash $path).Hash } else { $null }
                $actual | Should -Be $script:originalHashes[$path]
            }
        }
        foreach ($fixture in $script:fixtures) {
            (Test-Path "$($fixture.Receipt).failure.json") | Should -BeFalse -Because 'fixture timeout is a test failure'
        }
        }
        finally {
            foreach ($key in $script:runnerEnvironment.Keys) {
                [Environment]::SetEnvironmentVariable($key, $script:runnerEnvironment[$key], 'Process')
            }
        }
    }
    It 'Sessions off native OSC and BEL report truthful status without shell false positives' {
        Send-StatusSignal $script:otherNative -State 4
        Assert-Status $script:otherNative Paused
        foreach ($step in @(@{ State = 1; Text = 'Active' }, @{ State = 3; Text = 'Active' },
            @{ State = 2; Text = 'Error' }, @{ State = 4; Text = 'Paused' }, @{ State = 0; Text = 'Idle' })) {
            Send-StatusSignal $script:native -State $step.State
            Assert-Status $script:native $step.Text
            Assert-Status $script:otherNative Paused
            Send-StatusSignal $script:shell -State $step.State
            Assert-NoAgentStatus $script:shell
        }
        Send-StatusSignal $script:native -Kind bell
        Assert-Status $script:native 'Attention requested'
        Assert-Status $script:otherNative Paused
        Save-UiScreenshot -App $script:app -Path (Join-Path $script:evidence 'sessions-off-attention-and-paused.png') | Out-Null
        Send-StatusSignal $script:otherNative -State 2
        Assert-Status $script:otherNative Error
        Assert-Status $script:native 'Attention requested'
        Send-StatusSignal $script:shell -Kind bell
        Assert-NoAgentStatus $script:shell
        $panes = @(Get-WtPanes -App $script:app -WindowId $script:window -TabId $script:shell.Pane.tab_id)
        ($panes | Where-Object session_id -EQ $script:shell.Pane.session_id).native_agent_provider_id | Should -BeNullOrEmpty
        Assert-NoFabricatedBinding $script:native
        Assert-NoFabricatedBinding $script:otherNative
        Assert-NoFabricatedBinding $script:shell
        Send-StatusSignal $script:native -State 1
        Assert-Status $script:native Active
        Send-StatusSignal $script:native -State 0
        Assert-Status $script:native Idle
        Send-StatusSignal $script:otherNative -State 0
        Assert-Status $script:otherNative Idle
    }
    It 'Sessions on without hooks suppresses native OSC and BEL fallback' {
        if (-not $script:hookIsolationVerified) {
            throw 'Actual-host automation environment inheritance is unverified; ON reconciliation is unsafe.'
        }
        foreach ($fixture in @($script:native, $script:otherNative)) {
            Send-StatusSignal $fixture -State 0
            Assert-Status $fixture Idle
        }
        $beforeReceipts = @{}
        foreach ($provider in @('copilot', 'claude', 'codex', 'gemini')) {
            $beforeReceipts[$provider] = @(Get-Content (Join-Path $script:evidence "$provider-wrapper.log")).Count
        }
        Initialize-LogOffsets -App $script:app | Out-Null
        Set-WtSetting -App $script:app -Key agentSessionManagementEnabled -Value $true | Out-Null
        Wait-Until -TimeoutSec 15 -Because 'the product clears OFF metadata on the effective mode change' -Condition {
            $text = Get-StatusText $script:native
            $otherText = Get-StatusText $script:otherNative
            $statusPattern = '(?m)(^|[ ,·])(Active|Idle|Error|Paused|Attention requested|Waiting for input)($|[ ,·])'
            $text -and $otherText -and $text -notmatch $statusPattern -and $otherText -notmatch $statusPattern
        } | Out-Null
        Wait-Until -TimeoutSec 30 -Because 'ALL-provider reconciliation invokes only failing fixture CLIs' -Condition {
            $complete = $true
            foreach ($provider in $beforeReceipts.Keys) {
                if (@(Get-Content (Join-Path $script:evidence "$provider-wrapper.log")).Count -le $beforeReceipts[$provider]) {
                    $complete = $false
                }
            }
            $complete
        } | Out-Null
        $hookLog = Get-ItLogText -App $script:app -Name 'wta-install-hooks*.log' -SinceStart
        $hookLog | Should -Not -BeNullOrEmpty -Because 'capture real WTA reconciliation diagnostics alongside wrapper receipts'
        $hookLog | Set-Content (Join-Path $script:evidence 'hook-reconciliation.txt')
        Assert-NoAgentStatus $script:otherNative
        foreach ($state in @(1, 2, 3, 4, 0)) {
            Send-StatusSignal $script:native -State $state
            Assert-NoAgentStatus $script:native
        }
        Send-StatusSignal $script:native -Kind bell
        Assert-NoAgentStatus $script:native
        Set-WtSetting -App $script:app -Key agentSessionManagementEnabled -Value $false | Out-Null
        Wait-Until -TimeoutSec 15 -Because 'the product reloads Sessions OFF before fresh output' -Condition {
            $text = Get-StatusText $script:native
            $otherText = Get-StatusText $script:otherNative
            $idlePattern = '(?m)(^|[ ,·])Idle($|[ ,·])'
            $text -match $idlePattern -and $otherText -match $idlePattern
        } | Out-Null
        Send-StatusSignal $script:native -State 1
        Assert-Status $script:native Active
        Send-StatusSignal $script:native -State 0
        Assert-Status $script:native Idle
        Assert-NoFabricatedBinding $script:native
    }
}
