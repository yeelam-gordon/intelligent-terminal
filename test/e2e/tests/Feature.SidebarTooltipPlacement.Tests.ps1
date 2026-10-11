#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

Describe 'Feature: Sidebar tooltip placement' -Tag @('Feature', 'SidebarTooltipPlacement') {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\ItE2E\ItE2E.psd1') -Force
        . (Join-Path $PSScriptRoot 'helpers\TestTerminalCleanup.ps1')
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        & (Get-Module ItE2E) { Initialize-WtWin32Input }
    }

    It 'Sidebar tooltips leave adjacent rows selectable' {
        $package = Get-ItTestPackage
        if ($package -in @('Dev', 'Store', 'Auto') -or $package -notmatch '.+_.+') { throw 'Select an explicit private package family name.' }
        $target = Resolve-ItApp -Package $package
        Assert-WtPackageInactive -App $target
        foreach ($pair in @(@('TerminalApp.dll', $env:ITE2E_EXPECTED_APP_SHA256), @('wta.exe', $env:ITE2E_EXPECTED_WTA_SHA256))) {
            if ($pair[1] -notmatch '^[0-9a-fA-F]{64}$' -or
                (Get-FileHash -LiteralPath (Join-Path $target.InstallLocation $pair[0])).Hash -ne $pair[1]) {
                throw "Missing or mismatched exact-source build hash: $($pair[0])"
            }
        }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $app = $null; $launch = $null; $hover = $null; $originalCursor = $null; $primary = $null
        $dpi = [ItE2E.ItWtWin32Input]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
        if ($dpi -eq [IntPtr]::Zero) { throw 'Physical coordinate context unavailable.' }
        $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $titles = @("Alpha-$token", "Bravo-$token", "Charlie-$token")
        $profiles = @(0..2 | ForEach-Object { @{
            guid = "{$([guid]::NewGuid())}"; tabTitle = $titles[$_]
            name = if ($_ -eq 1) { "Terminal profile`nFixture line two`nFixture line three`nFixture line four: Bravo" } else { $titles[$_] }
            commandline = 'cmd.exe /d /k'; suppressApplicationTitle = $true; shellIntegrationEnabled = $false
        } })
        function Get-HeaderRows([string]$Layout) {
            $root = [Windows.Automation.AutomationElement]::FromHandle([IntPtr][long]$app.Hwnd)
            if ($root.Current.ProcessId -ne $app.Pid) { throw 'Window ownership changed.' }
            $id = if ($Layout -eq 'vertical') { 'ItemsList' } else { 'TabView' }
            $list = $root.FindFirst([Windows.Automation.TreeScope]::Descendants,
                [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, $id))
            if (-not $list -or $list.Current.IsOffscreen) { throw "Missing visible $id." }
            $kind = if ($Layout -eq 'vertical') { [Windows.Automation.ControlType]::ListItem } else { [Windows.Automation.ControlType]::TabItem }
            $peers = @($list.FindAll([Windows.Automation.TreeScope]::Descendants,
                [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, $kind)))
            foreach ($title in $titles) {
                $matches = @($peers | Where-Object { $_.Current.ProcessId -eq $app.Pid -and $_.Current.Name -ceq $title -and -not $_.Current.IsOffscreen })
                if ($matches.Count -ne 1) { throw "Ambiguous visible header: $title" }
                $peer = $matches[0]; $band = $peer.Current.BoundingRectangle
                $buttons = @($peer.FindAll([Windows.Automation.TreeScope]::Descendants,
                    [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button)) |
                    Where-Object { $_.Current.ProcessId -eq $app.Pid -and -not $_.Current.IsOffscreen })
                if ($Layout -eq 'vertical') {
                    $anchor = @($buttons | Where-Object { $_.Current.AutomationId -eq 'TabCloseButton' })
                    if ($anchor.Count -ne 1) { throw 'Missing ordinary singleton header activation band.' }
                    $box = $anchor[0].Current.BoundingRectangle
                    $band = [Windows.Rect]::new($band.Left, $box.Top, $band.Width, $box.Height)
                }
                if ($band.IsEmpty -or $band.Width -le 0 -or $band.Height -le 0 -or
                    -not $list.Current.BoundingRectangle.Contains($band) -or -not $root.Current.BoundingRectangle.Contains($band)) { throw 'Clipped header.' }
                [pscustomobject]@{ Peer = $peer; Band = $band; Buttons = $buttons; Runtime = ($peer.GetRuntimeId() -join ',')
                    Point = [Windows.Point]::new([int]($band.Left + $band.Width / 2), [int]($band.Top + $band.Height / 2)) }
            }
        }
        function Assert-HeaderInput($row, [switch]$Cursor) {
            if ($clock.Elapsed.TotalSeconds -ge 90) { throw 'Fixture exceeded its 90-second action budget.' }
            $process = Get-Process -Id $app.Pid -ErrorAction Stop
            if (-not $app.Launched -or $app.OwnedProcess.HasExited -or $process.StartTime -ne $app.OwnedProcess.StartTime -or
                $process.Path -ne $app.OwnedProcess.Path -or ($row.Peer.GetRuntimeId() -join ',') -ne $row.Runtime) { throw 'Stale creation/header lease.' }
            $point = [ItE2E.ItWtWin32Input+POINT]::new(); $point.X = $row.Point.X; $point.Y = $row.Point.Y
            $hit = [ItE2E.ItWtWin32Input]::WindowFromPoint($point)
            if ([ItE2E.ItWtWin32Input]::GetAncestor($hit, 2) -ne [IntPtr][long]$app.Hwnd -or
                [ItE2E.ItWtWin32Input]::GetWindowProcessId($hit) -ne $app.Pid -or
                -not [ItE2E.ItWtWin32Input]::IsOwnedRootOrPopup([ItE2E.ItWtWin32Input]::GetForegroundWindow(), [IntPtr][long]$app.Hwnd, $app.Pid)) {
                throw 'Header input is covered or foreground is foreign.'
            }
            if (-not $row.Band.Contains($row.Point) -or @($row.Buttons | Where-Object { $_.Current.BoundingRectangle.Contains($row.Point) }).Count) { throw 'Header center intersects an action.' }
            foreach ($key in @(1, 2, 4, 5, 6, 16, 17, 18, 91, 92)) {
                if ([ItE2E.ItWtWin32Input]::IsKeyDown($key)) { throw 'Held user input; no injection authorized.' }
            }
            if ($Cursor) {
                $position = [ItE2E.ItWtWin32Input]::GetCursorPosition()
                if ($position[0] -ne $point.X -or $position[1] -ne $point.Y) { throw 'Physical cursor left the intended header center.' }
            }
        }
        function Get-OwnedTooltips {
            $condition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$app.Pid)
            foreach ($window in [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children, $condition)) {
                if ($window.Current.ProcessId -ne $app.Pid) { throw 'Popup root changed ownership.' }
                foreach ($tip in $window.FindAll([Windows.Automation.TreeScope]::Subtree,
                    [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ToolTip))) {
                    if ($tip.Current.ProcessId -ne $app.Pid) { throw 'Foreign tooltip.' }
                    if (-not $tip.Current.IsOffscreen -and $tip.Current.BoundingRectangle.Width -gt 0 -and $tip.Current.BoundingRectangle.Height -gt 0) { $tip }
                }
            }
        }
        try {
            $launch = Get-Date
            $app = Start-Terminal -Package $package -TimeoutSec 30 -PassFre $true -State @{
                sidebarLayoutMigrationCompleted = $true; sidebarIntroductionShown = $true
            } -Settings @{
                language = 'en-US'; tabLayout = 'horizontal'; startupActions = ''; firstWindowPreference = 'defaultProfile'
                windowingBehavior = 'useNew'; 'warning.confirmOnClose' = 'never'; autoErrorDetectionEnabled = $false; autoFixEnabled = $false
                defaultProfile = $profiles[0].guid; profiles = @{ list = $profiles }
            }
            $loaded = @($app.OwnedProcess.Modules | Where-Object ModuleName -eq 'TerminalApp.dll')
            if ($loaded.Count -ne 1 -or $loaded[0].FileName -ne (Join-Path $target.InstallLocation 'TerminalApp.dll') -or
                (Get-FileHash -LiteralPath $loaded[0].FileName).Hash -ne $env:ITE2E_EXPECTED_APP_SHA256) { throw 'Wrong loaded App module.' }
            $originalCursor = [ItE2E.ItWtWin32Input]::GetCursorPosition()
            $identities = @((Get-ActivePane -App $app))
            foreach ($index in @(1, 2)) {
                $identities += Invoke-WtCli -App $app -Arguments @('new-tab', '-p', $profiles[$index].guid, '-n', $titles[$index], '-w', [string]$app.WindowId)
            }
            $identities = @($identities | ForEach-Object { (Invoke-WtCli -App $app -Arguments @('get-pane-context', '--target', $_.session_id)).pane })
            $expectedText = $null
            foreach ($layout in @('horizontal', 'vertical')) {
                Set-WtSetting -App $app -Key tabLayout -Value $layout | Out-Null
                Wait-UiElement -App $app -Selector $(if ($layout -eq 'vertical') { 'ItemsList' } else { 'TabView' }) -TimeoutSec 10 | Out-Null
                Set-WtPaneFocus -App $app -SessionId $identities[1].session_id | Out-Null
                if (-not (Set-WtWindowForeground -App $app -Attempts 2)) { throw 'Cannot acquire owned foreground.' }
                $rows = @(Get-HeaderRows $layout); $owner = $rows[1]
                $tree = Get-UiTree -App $app -Selector $(if ($layout -eq 'vertical') { 'ItemsList' } else { 'TabView' }) -Depth 8
                $slugs = @([regex]::Matches($tree, '(?m)^\s*(?<slug>\S+)\s+' + $(if ($layout -eq 'vertical') { 'ListItem' } else { 'TabItem' }) + '\s+"' + [regex]::Escape($titles[1]) + '"'))
                if ($slugs.Count -ne 1) { throw 'No unique winapp semantic header selector.' }
                $box = $owner.Peer.Current.BoundingRectangle
                if ([int]($box.Left + $box.Width / 2) -ne $owner.Point.X -or [int]($box.Top + $box.Height / 2) -ne $owner.Point.Y) { throw 'Semantic center differs from the safe activation-band center.' }
                if (@(Get-OwnedTooltips).Count) { throw 'Tooltip already open before controlled hover.' }
                Assert-HeaderInput $owner
                $start = [Diagnostics.ProcessStartInfo]::new((Get-Command winapp -ErrorAction Stop).Source)
                $start.UseShellExecute = $false; $start.CreateNoWindow = $true
                $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
                $start.Environment['WINAPP_CLI_TELEMETRY_OPTOUT'] = '1'
                foreach ($argument in @('ui', 'hover', $slugs[0].Groups['slug'].Value, '-w', [string]$app.Hwnd, '--dwell-time', '5000', '--json')) { $start.ArgumentList.Add($argument) }
                $hover = [Diagnostics.Process]::Start($start)
                $stdout = $hover.StandardOutput.ReadToEndAsync(); $stderr = $hover.StandardError.ReadToEndAsync()
                $tip = Wait-Until -TimeoutSec 4 -IntervalSec 0.1 -Because 'a real tooltip during genuine hover' -Condition {
                    if ($hover.HasExited) { throw 'Hover ended before observation.' }
                    $found = @(Get-OwnedTooltips)
                    if ($found.Count -gt 1) { throw 'Ambiguous owned tooltip.' }
                    if ($found.Count -eq 1) { Assert-HeaderInput $owner -Cursor; $found[0] }
                }
                $fresh = @(Get-HeaderRows $layout)
                ($fresh.Runtime -join '|') | Should -BeExactly ($rows.Runtime -join '|')
                (($fresh | ForEach-Object { $_.Band.ToString() }) -join '|') | Should -BeExactly (($rows | ForEach-Object { $_.Band.ToString() }) -join '|')
                $tip.Current.Name | Should -BeExactly $owner.Peer.Current.HelpText
                $tip.Current.Name | Should -Match ([regex]::Escape($profiles[1].name))
                if ($layout -eq 'horizontal') { $expectedText = $tip.Current.Name }
                else {
                    $tip.Current.Name | Should -BeExactly $expectedText
                    foreach ($neighbor in @(0, 2)) {
                        $intersection = [Windows.Rect]::Intersect($tip.Current.BoundingRectangle, $fresh[$neighbor].Band)
                        $area = if ($intersection.IsEmpty) { 0 } else { $intersection.Width * $intersection.Height }
                        $area | Should -Be 0 -Because 'both adjacent activation bands must remain unobstructed'
                    }
                }
                Assert-HeaderInput $fresh[0]
                $alpha = @([regex]::Matches($tree, '(?m)^\s*(?<slug>\S+)\s+' + $(if ($layout -eq 'vertical') { 'ListItem' } else { 'TabItem' }) + '\s+"' + [regex]::Escape($titles[0]) + '"'))
                if ($alpha.Count -ne 1) { throw 'No unique physical Alpha header selector.' }
                Invoke-Native -FilePath $start.FileName -Arguments @('ui', 'click', $alpha[0].Groups['slug'].Value, '-w', [string]$app.Hwnd, '--json') -TimeoutSec 15 |
                    ForEach-Object { if ($_.TimedOut -or $_.ExitCode -ne 0) { throw "Physical Alpha click failed: $($_.StdErr)" } }
                Wait-Until -TimeoutSec 5 -Because 'physical Alpha selection preserves original identity' -Condition {
                    $active = Get-ActivePane -App $app
                    $active.session_id -eq $identities[0].session_id -and $active.tab_id -eq $identities[0].tab_id -and $active.window_id -eq $identities[0].window_id
                } | Out-Null
                if (-not (Wait-ItProcessDeadline -Process $hover -TimeoutSec 7) -or $hover.ExitCode -ne 0) { throw 'Genuine hover child failed or exceeded deadline.' }
                if (-not $stdout.Wait(1000) -or -not $stderr.Wait(1000)) { throw 'Hover output drain timed out.' }
                $hover.Dispose(); $hover = $null
                Wait-Until -TimeoutSec 3 -Because 'the owned tooltip closes after hover' -Condition { @(Get-OwnedTooltips).Count -eq 0 } | Out-Null
                $tabs = @(Get-WtTabs -App $app -WindowId $app.WindowId)
                ($tabs.tab_id -join '|') | Should -BeExactly ($identities.tab_id -join '|')
                foreach ($identity in $identities) {
                    @((Get-WtPanes -App $app -TabId $identity.tab_id -WindowId $app.WindowId)).session_id | Should -BeExactly $identity.session_id
                }
            }
        }
        catch { $primary = $_ }
        finally {
            $cleanup = [Collections.Generic.List[Exception]]::new()
            try {
                if ($hover) {
                    try { if (-not (Wait-ItProcessDeadline -Process $hover -TimeoutSec 7)) { $hover.Kill(); throw 'Owned hover child required timeout termination.' } }
                    finally { $hover.Dispose() }
                }
                if ($app -and $originalCursor) {
                    $cursor = [ItE2E.ItWtWin32Input]::GetCursorPosition()
                    $point = [ItE2E.ItWtWin32Input+POINT]::new(); $point.X = $cursor[0]; $point.Y = $cursor[1]
                    if (-not [ItE2E.ItWtWin32Input]::IsOwnedRootOrPopup([ItE2E.ItWtWin32Input]::WindowFromPoint($point), [IntPtr][long]$app.Hwnd, $app.Pid)) { throw 'Cursor recovery refused on foreign surface.' }
                    if (-not [ItE2E.ItWtWin32Input]::SetCursorPos($originalCursor[0], $originalCursor[1])) { throw 'Cursor recovery failed.' }
                }
            } catch { $cleanup.Add($_.Exception) }
            try { Stop-TestTerminal -App $app -Target $target -LaunchStarted $launch } catch { $cleanup.Add($_.Exception) }
            if ([ItE2E.ItWtWin32Input]::SetThreadDpiAwarenessContext($dpi) -eq [IntPtr]::Zero) { $cleanup.Add([Exception]::new('DPI recovery failed.')) }
            if ($cleanup.Count) {
                if ($primary) { $cleanup.Insert(0, $primary.Exception) }
                throw [AggregateException]::new('Tooltip action/cleanup failed.', $cleanup.ToArray())
            }
        }
        if ($primary) { throw $primary }
    }
}
