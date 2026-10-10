#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
# Complete authored matrix; no live acceptance without exact-source native/baseline evidence.
Describe 'Feature: Sidebar tooltip placement' -Tag @('Feature', 'SidebarTooltipPlacement') {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\ItE2E\ItE2E.psd1') -Force
        . (Join-Path $PSScriptRoot 'helpers\SidebarTooltipOracle.ps1')
        . (Join-Path $PSScriptRoot 'helpers\TestTerminalCleanup.ps1')
        Assert-SidebarTooltipCommands (Join-Path $PSScriptRoot 'Feature.SidebarTooltipPlacement.Tests.ps1')
        $desktop = Initialize-SidebarTooltipDesktop
        & (Get-Module ItE2E) { Initialize-WtWin32Input }
        $script:package = Get-ItTestPackage
        if ($script:package -eq 'Store') { throw 'This regression requires an explicitly selected exact-source Dev/private package.' }
        foreach ($name in @('ITE2E_EXPECTED_APP_SHA256', 'ITE2E_EXPECTED_WTA_SHA256', 'ITE2E_SOURCE_COMMIT')) {
            if (-not [Environment]::GetEnvironmentVariable($name)) { throw "Missing build receipt: $name" }
        }
        if ($env:ITE2E_SOURCE_COMMIT -notmatch '^[0-9a-fA-F]{40}(?:[+ ].*)?$') { throw 'Source receipt must identify a complete commit.' }
        if (-not $env:ITE2E_BUILD_RECEIPT) { throw 'Supply ITE2E_BUILD_RECEIPT from the source build, not installed-package discovery.' }
        $receipt = Get-Content -LiteralPath $env:ITE2E_BUILD_RECEIPT -Raw | ConvertFrom-Json
        if ($receipt.sourceHead -cne $env:ITE2E_SOURCE_COMMIT) { throw 'Build receipt source mismatch.' }
        $script:target = Resolve-ItApp -Package $script:package
        if ($receipt.installedIdentity.PFN -cne $script:target.Package) { throw 'Build receipt package mismatch.' }
        Assert-WtPackageInactive -App $script:target
        $script:baselineMode = $env:ITE2E_TOOLTIP_BASELINE -eq '1'
        if ($script:baselineMode) { Assert-SidebarTooltipOriginalArchive $receipt }
        foreach ($pair in @(@('TerminalApp.dll', $env:ITE2E_EXPECTED_APP_SHA256), @('wta.exe', $env:ITE2E_EXPECTED_WTA_SHA256))) {
            if ((Get-FileHash -LiteralPath (Join-Path $script:target.InstallLocation $pair[0])).Hash -ne $pair[1]) { throw "Exact-source payload mismatch: $($pair[0])" }
            $entry = @($receipt.hashes | Where-Object file -eq $pair[0])
            if ($entry.Count -ne 1 -or $entry[0].hash -ne $pair[1] -or -not $entry[0].corresponding -or
                (-not $script:baselineMode -and (Get-FileHash -LiteralPath $entry[0].ownSourceOutput).Hash -ne $pair[1]) -or
                [IO.Path]::GetFullPath($entry[0].installed) -cne [IO.Path]::GetFullPath((Join-Path $script:target.InstallLocation $pair[0]))) {
                throw 'Build output/package correspondence not established.'
            }
        }
        foreach ($path in @($script:target.SettingsPath, $script:target.StatePath)) {
            if ((Test-Path "$path.e2ebak") -or (Test-Path "$path.e2ebak.missing")) { throw "Unowned recovery backup: $path" }
        }
        $root = if ($env:ITE2E_ARTIFACT_ROOT) { $env:ITE2E_ARTIFACT_ROOT } else { Join-Path $PSScriptRoot '..\artifacts' }
        $script:evidence = Join-Path $root ('sidebar-tooltip-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $script:evidence | Out-Null
        $receipt | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $script:evidence 'build-receipt.json')
        $script:horizontalSamples = [Collections.Generic.List[object]]::new()
        $script:nativeHash = (Get-FileHash -LiteralPath "$env:WINDIR\System32\Windows.UI.Xaml.dll").Hash
        if (-not $script:baselineMode) {
            if (-not $env:ITE2E_TOOLTIP_NATIVE_RECEIPT -or -not $env:ITE2E_TOOLTIP_BASELINE_RECEIPT) {
                throw 'Supply hosted native lifecycle and actual original-build Horizontal baseline receipts.'
            }
            Assert-SidebarTooltipNativeReceipt (Get-Content $env:ITE2E_TOOLTIP_NATIVE_RECEIPT -Raw | ConvertFrom-Json) `
                $env:ITE2E_SOURCE_COMMIT $env:ITE2E_EXPECTED_APP_SHA256
            $script:baseline = Get-Content $env:ITE2E_TOOLTIP_BASELINE_RECEIPT -Raw | ConvertFrom-Json
            if ($script:baseline.sourceHead -notmatch '^[0-9a-fA-F]{40}(?:[+ ].*)?$' -or
                $script:baseline.nativeHash -ne $script:nativeHash -or $script:baseline.samples.Count -ne 12) {
                throw 'Original immutable source/native baseline is missing or incomplete.'
            }
            $baseBuild = Get-Content $script:baseline.buildReceipt -Raw | ConvertFrom-Json
            if ((Get-FileHash -LiteralPath $script:baseline.buildReceipt).Hash -ne $script:baseline.buildReceiptSHA256 -or
                $baseBuild.sourceHead -cne $script:baseline.sourceHead) { throw 'Baseline build provenance mismatch.' }
            if ($baseBuild.baselineOriginalMsix) { Assert-SidebarTooltipOriginalArchive $baseBuild }
            foreach ($file in @('TerminalApp.dll','wta.exe')) {
                $entry = @($baseBuild.hashes | Where-Object file -eq $file)
                if ($entry.Count -ne 1 -or -not $entry[0].corresponding -or
                    (Get-FileHash -LiteralPath $entry[0].installed).Hash -ne $entry[0].hash) { throw 'Immutable baseline payload changed.' }
            }
            $baseApp = @($baseBuild.hashes | Where-Object file -eq 'TerminalApp.dll')[0]
            foreach ($sample in $script:baseline.samples) {
                if ($sample.Source -cne $script:baseline.sourceHead -or $sample.AppHash -ne $baseApp.hash -or
                    (Get-FileHash -LiteralPath $sample.InputReceipt).Hash -ne $sample.InputReceiptSHA256) { throw 'Baseline observation provenance changed.' }
                Assert-SidebarTooltipInputReceipt @{path=$sample.InputReceipt;sha256=$sample.InputReceiptSHA256} `
                    $sample.Pid $sample.RunToken (Join-Path ([IO.Path]::GetDirectoryName($baseApp.installed)) 'WindowsTerminal.exe')
            }
        }
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class TooltipMonitor {
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
 [StructLayout(LayoutKind.Sequential)] public struct INFO { public uint Size; public RECT Screen,Work; public uint Flags; }
 [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr hwnd,uint flags);
 [DllImport("user32.dll",SetLastError=true)] static extern bool GetMonitorInfo(IntPtr monitor,ref INFO info);
 [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
 [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
 [StructLayout(LayoutKind.Sequential)] public struct PLACEMENT { public uint Length,Flags,Show; public POINT Min,Max; public RECT Normal; }
 [DllImport("user32.dll",SetLastError=true)] public static extern bool GetWindowPlacement(IntPtr hwnd,ref PLACEMENT p);
 [DllImport("user32.dll",SetLastError=true)] public static extern bool SetWindowPlacement(IntPtr hwnd,ref PLACEMENT p);
 [DllImport("user32.dll",SetLastError=true)] public static extern bool SetWindowPos(IntPtr hwnd,IntPtr after,int x,int y,int width,int height,uint flags);
 public static INFO Read(IntPtr hwnd) {
  var info=new INFO(); info.Size=(uint)Marshal.SizeOf(info);
  if(!GetMonitorInfo(MonitorFromWindow(hwnd,2),ref info)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
  return info;
 }
}
'@

        function Get-TooltipRows($app, $titles, [switch]$Horizontal, [switch]$Collapsed) {
            $window = [Windows.Automation.AutomationElement]::FromHandle([IntPtr][long]$app.Hwnd)
            if ($window.Current.ProcessId -ne $app.Pid) { throw 'Foreign HWND.' }
            $id = if ($Horizontal) { 'TabView' } else { 'ItemsList' }
            $container = $window.FindFirst([Windows.Automation.TreeScope]::Descendants,
                [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, $id))
            if (-not $container -or $container.Current.IsOffscreen) { throw "Missing $id." }
            $type = if ($Horizontal) { [Windows.Automation.ControlType]::TabItem } else { [Windows.Automation.ControlType]::ListItem }
            foreach ($title in $titles) {
                $rows = @($container.FindAll([Windows.Automation.TreeScope]::Descendants,
                    [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, $type)) |
                    Where-Object { $_.Current.Name -ceq $title -and $_.Current.HelpText.Contains($title) -and
                        $_.Current.ProcessId -eq $app.Pid -and -not $_.Current.IsOffscreen })
                if ($rows.Count -ne 1) { throw "Ambiguous current row: $title" }
                $row = $rows[0]
                $parts = @($row.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition))
                $band = $row.Current.BoundingRectangle
                if (-not $Horizontal) {
                    $anchors = @($parts | Where-Object { $_.Current.AutomationId -eq 'TabGroupToggleButton' -and -not $_.Current.IsOffscreen })
                    if (-not $anchors.Count) { $anchors = @($parts | Where-Object { $_.Current.AutomationId -eq 'TabCloseButton' -and -not $_.Current.IsOffscreen }) }
                    if ($anchors.Count -eq 1) {
                        $a = $anchors[0].Current.BoundingRectangle
                        $band = [Windows.Rect]::new($band.Left, $a.Top, $band.Width, $a.Height)
                    }
                    elseif (-not $Collapsed -or $anchors.Count -gt 1 -or @($parts | Where-Object {
                        $_.Current.AutomationId -eq 'PaneActivateButton' -and -not $_.Current.IsOffscreen
                    }).Count) { throw 'Missing unique activation band; compact singleton fallback refused.' }
                }
                Assert-SidebarTooltipRect $band
                if (-not $container.Current.BoundingRectangle.Contains($band)) { throw 'Clipped activation band.' }
                $actions = @($parts | Where-Object { $_.Current.ControlType -eq [Windows.Automation.ControlType]::Button -and
                    -not $_.Current.IsOffscreen -and $_.Current.BoundingRectangle.Width -gt 0 } | ForEach-Object { $_.Current.BoundingRectangle })
                [pscustomobject]@{ Peer=$row; Band=$band; Points=@(Get-SidebarTooltipPoints $band $actions)
                    RuntimeId=($row.GetRuntimeId() -join ','); Help=$row.Current.HelpText; Shortcut=$row.Current.AcceleratorKey
                    Rail=$container.Current.BoundingRectangle; Frame=$window.Current.BoundingRectangle }
            }
        }
        function Get-TooltipCandidates($app) {
            $pidCondition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$app.Pid)
            $tipCondition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ToolTip)
            @(
                foreach ($window in [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children, $pidCondition)) {
                    foreach ($tip in $window.FindAll([Windows.Automation.TreeScope]::Subtree, $tipCondition)) {
                        if ($tip.Current.IsOffscreen) { continue }
                        $text = $tip.Current.Name
                        if (-not $text) {
                            $leaves = @($tip.FindAll([Windows.Automation.TreeScope]::Descendants,
                                [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Text)))
                            $unique = @{}
                            $ordered = [Collections.Generic.List[string]]::new()
                            foreach ($leaf in $leaves) {
                                if ($leaf.Current.ProcessId -ne $app.Pid) { throw 'Foreign tooltip text leaf.' }
                                $key = $leaf.GetRuntimeId() -join ','
                                if ($unique.ContainsKey($key)) { continue }
                                if ($leaf.FindAll([Windows.Automation.TreeScope]::Children,
                                    [Windows.Automation.Condition]::TrueCondition).Count -eq 0) {
                                    $unique[$key] = $leaf.Current.Name
                                    $ordered.Add($leaf.Current.Name)
                                }
                            }
                            if ($unique.Count -eq 0 -or @($ordered | Select-Object -Unique).Count -ne $ordered.Count) {
                                throw 'Missing or duplicated tooltip semantic leaves.'
                            }
                            $text = $ordered -join "`n"
                        }
                        [pscustomobject]@{ RuntimeId=($tip.GetRuntimeId() -join ','); Pid=$tip.Current.ProcessId
                            Text=$text; Bounds=$tip.Current.BoundingRectangle; Offscreen=$tip.Current.IsOffscreen }
                    }
                }
            )
        }
        function Assert-TooltipCanonical($app, $titles, $identities) {
            $tabs = @(Get-WtTabs -App $app -WindowId $app.WindowId)
            if ($tabs.Count -ne 3 -or ($tabs.title -join '|') -cne ($titles -join '|') -or
                ($tabs.tab_id -join '|') -cne ($identities.tab_id -join '|')) { throw 'Canonical tab order changed.' }
            foreach ($identity in $identities) {
                $panes = @(Get-WtPanes -App $app -TabId $identity.tab_id -WindowId $app.WindowId)
                if ($panes.Count -ne 1 -or $panes[0].session_id -cne $identity.session_id) { throw 'Original singleton identity changed.' }
            }
        }
        function Set-TooltipColdPointer($app, $Owner) {
            $process = Get-Process -Id $app.Pid -ErrorAction Stop
            if (-not $app.Launched -or $app.OwnedProcess.HasExited -or
                $process.StartTime -ne $app.OwnedProcess.StartTime -or $process.Path -cne $app.OwnedProcess.Path -or
                [ItE2E.ItWtWin32Input]::GetWindowProcessId([IntPtr][long]$app.Hwnd) -ne $app.Pid) {
                throw 'Cold association requires the original current native window lease.'
            }
            Assert-SidebarTooltipInputReceipt $script:localeInputReceipt $app.Pid $app.InputRunToken $app.OwnedProcess.Path
            $cursor = [ItE2E.ItWtWin32Input]::GetCursorPosition()
            $point = [ItE2E.ItWtWin32Input+POINT]::new();$point.X=$cursor[0];$point.Y=$cursor[1]
            $hit = [ItE2E.ItWtWin32Input]::WindowFromPoint($point)
            $fullyVisible = $false;$targetRect = $null
            if ($Owner) {
                if ($Owner.Peer.Current.ProcessId -ne $app.Pid -or $Owner.Peer.Current.IsOffscreen -or
                    ($Owner.Peer.GetRuntimeId()-join ',') -cne $Owner.RuntimeId) { throw 'Cold association owner is stale/foreign.' }
                $targetRect=$Owner.Band
                Assert-SidebarTooltipRect $targetRect
                $screen=[TooltipMonitor]::Read([IntPtr][long]$app.Hwnd).Screen
                $fullyVisible=$Owner.Rail.Contains($targetRect) -and $Owner.Frame.Contains($targetRect) -and
                    $targetRect.Left -ge $screen.Left -and $targetRect.Right -le $screen.Right -and
                    $targetRect.Top -ge $screen.Top -and $targetRect.Bottom -le $screen.Bottom
            }
            Invoke-SidebarTooltipColdExit -TipCount @(Get-TooltipCandidates $app).Count -OwnedRoot ([long]$app.Hwnd) `
                -CursorRoot ([ItE2E.ItWtWin32Input]::GetAncestor($hit,2).ToInt64()) `
                -CursorPid ([int][ItE2E.ItWtWin32Input]::GetWindowProcessId($hit)) -OwnerPid $app.Pid `
                -TargetRect $targetRect -CursorPoint @{X=$cursor[0];Y=$cursor[1]} -LeaseOwned $true -OwnerFullyVisible $fullyVisible -Move {
            if ([ItE2E.ItWtWin32Input]::GetWindowProcessId([IntPtr][long]$app.Hwnd) -ne $app.Pid) {
                throw 'Cold-exit native root changed ownership; UIA query refused.'
            }
            $root = [Windows.Automation.AutomationElement]::FromHandle([IntPtr][long]$app.Hwnd)
            if ($root.Current.ProcessId -ne $app.Pid) { throw 'Cold-exit root ownership changed.' }
            $terms = @($root.FindAll([Windows.Automation.TreeScope]::Descendants,
                [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ClassNameProperty,'TermControl')) |
                Where-Object { $_.Current.ProcessId -eq $app.Pid -and -not $_.Current.IsOffscreen })
            if ($terms.Count -ne 1) { throw 'No unique owned content peer for cold exit.' }
            $box = $terms[0].Current.BoundingRectangle
            Assert-SidebarTooltipRect $box
            $screen = [TooltipMonitor]::Read([IntPtr][long]$app.Hwnd).Screen
            $visible = @{Left=[math]::Max($box.Left,$screen.Left);Right=[math]::Min($box.Right,$screen.Right)
                Top=[math]::Max($box.Top,$screen.Top);Bottom=[math]::Min($box.Bottom,$screen.Bottom)}
            Assert-SidebarTooltipRect $visible
            $x = [int](($visible.Left+$visible.Right)/2); $y = [int](($visible.Top+$visible.Bottom)/2)
            $target = [ItE2E.ItWtWin32Input+POINT]::new();$target.X=$x;$target.Y=$y
            $native = [ItE2E.ItWtWin32Input]::WindowFromPoint($target)
            $foreground = [ItE2E.ItWtWin32Input]::GetForegroundWindow()
            if ($terms[0].Current.ProcessId -ne $app.Pid) { throw 'Cold-exit expected peer changed ownership.' }
            @{
                stage='before-cold-guard';pid=$app.Pid;hwnd=$app.Hwnd;runToken=$app.InputRunToken
                image=$app.OwnedProcess.Path;startUtc=$app.OwnedProcess.StartTime.ToUniversalTime().ToString('o')
                receipt=$app.InputReceiptPath;cursor=$cursor;target=@{X=$x;Y=$y}
                expectedRuntimeId=($terms[0].GetRuntimeId()-join ',');expectedBounds=$box;visibleBounds=$visible
                nativeHit=$native.ToInt64();nativeAncestor=[ItE2E.ItWtWin32Input]::GetAncestor($native,2).ToInt64()
                nativePid=[ItE2E.ItWtWin32Input]::GetWindowProcessId($native)
                cursorHit=$hit.ToInt64();cursorAncestor=[ItE2E.ItWtWin32Input]::GetAncestor($hit,2).ToInt64()
                cursorPid=[ItE2E.ItWtWin32Input]::GetWindowProcessId($hit)
                foreground=$foreground.ToInt64();foregroundPid=[ItE2E.ItWtWin32Input]::GetWindowProcessId($foreground)
            } | ConvertTo-Json -Depth 6 -Compress | Add-Content (Join-Path $script:evidence 'cold-point.jsonl')
            & (Get-Module ItE2E) { param($a,$x,$y,$p)
                [void](Get-ItOwnedPointerPeer -App $a -X $x -Y $y -ExpectedPeer $p)
                if (-not [ItE2E.ItWtWin32Input]::SetCursorPos($x,$y)) { throw 'Cold pointer movement refused.' }
                [void](Get-ItOwnedPointerPeer -App $a -X $x -Y $y -ExpectedPeer $p -ExpectedCursor @($x,$y))
            } $app $x $y $terms[0]
            $clock = [Diagnostics.Stopwatch]::StartNew()
            do {
                if (@(Get-TooltipCandidates $app).Count -eq 0) { return }
                Start-Sleep -Milliseconds 100
            } while ($clock.Elapsed.TotalSeconds -lt 5)
            throw 'Owned tooltip did not disappear after controlled exit.'
            } | Out-Null
        }
        function Set-TooltipRailCollapsed($app) {
            $pattern = Get-WtReswTextRegex -Key VerticalTabsCollapsePane
            if (-not $pattern) { throw 'Localized rail collapse action unavailable.' }
            $root = [Windows.Automation.AutomationElement]::FromHandle([IntPtr][long]$app.Hwnd)
            $buttons = @($root.FindAll([Windows.Automation.TreeScope]::Descendants,
                [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [Windows.Automation.ControlType]::Button)) | Where-Object {
                $_.Current.ProcessId -eq $app.Pid -and -not $_.Current.IsOffscreen -and $_.Current.Name -match $pattern
            })
            if ($buttons.Count -ne 1) { throw 'Ambiguous localized rail-collapse owner.' }
            $buttons[0].GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
        }
        function Set-TooltipOwnedFrame($app, $frame, $Owner) {
            $process = Get-Process -Id $app.Pid -ErrorAction Stop
            if (-not $app.Launched -or $app.OwnedProcess.HasExited -or
                $process.StartTime -ne $app.OwnedProcess.StartTime -or $process.Path -cne $app.OwnedProcess.Path -or
                [ItE2E.ItWtWin32Input]::GetWindowProcessId([IntPtr][long]$app.Hwnd) -ne $app.Pid -or
                -not (Set-WtWindowForeground -App $app)) { throw 'Owned frame mutation lease/foreground refused.' }
            Set-TooltipColdPointer $app $Owner
            $cursor = [ItE2E.ItWtWin32Input]::GetCursorPosition()
            & (Get-Module ItE2E) { param($a,$p)
                [void](Get-ItOwnedPointerPeer -App $a -X $p[0] -Y $p[1] -ExpectedCursor $p)
            } $app $cursor
            if (-not [TooltipMonitor]::SetWindowPos([IntPtr][long]$app.Hwnd,[IntPtr]::Zero,
                [int]$frame.Left,[int]$frame.Top,[int]($frame.Right-$frame.Left),[int]($frame.Bottom-$frame.Top),0x0014)) {
                throw 'Owned physical frame mutation failed.'
            }
        }
        function Wait-TooltipOpen($app, $owner, $point, $foreign) {
            $clock = [Diagnostics.Stopwatch]::StartNew(); $previous = $null
            do {
                & (Get-Module ItE2E) { param($a,$p,$x,$y)
                    [void](Get-ItOwnedPointerPeer -App $a -X $x -Y $y -ExpectedPeer $p -ExpectedCursor @($x,$y))
                } $app $owner.Peer $point.X $point.Y
                $candidates = @(Get-TooltipCandidates $app)
                if ($candidates.Count) {
                    $tip = Select-SidebarTooltip $candidates $app.Pid $owner.Help $foreign
                    if (-not $previous) {
                        @{stage='first-observed';elapsedMs=$clock.ElapsedMilliseconds;popup=$tip;owner=$owner.Band} |
                            ConvertTo-Json -Depth 6 -Compress | Add-Content (Join-Path $script:evidence 'first-observed.jsonl')
                    }
                    if ($previous -and $previous.RuntimeId -ceq $tip.RuntimeId) {
                        $settled = $true
                        foreach ($edge in @('Left','Top','Right','Bottom')) {
                            if ([math]::Abs($previous.Bounds.$edge-$tip.Bounds.$edge) -gt 1) { $settled = $false }
                        }
                        if ($settled) {
                            Assert-SidebarTooltipStable $previous $tip
                            return $tip
                        }
                    }
                    $previous = $tip
                }
                Start-Sleep -Milliseconds 100
            } while ($clock.Elapsed.TotalSeconds -lt 5)
            throw 'No associated owned full-content tooltip settled within five seconds.'
        }
        function Assert-TooltipSample($app, $titles, $identities, [switch]$Horizontal, [switch]$Rtl, [switch]$Collapsed, [switch]$ScreenFallback) {
            $rows = @(Get-TooltipRows $app $titles -Horizontal:$Horizontal -Collapsed:$Collapsed)
            $owner = $rows[1]
            if (-not $Horizontal) {
                Assert-SidebarTooltipRect $owner.Rail
                Assert-SidebarTooltipRect $owner.Frame
                $center = ($owner.Frame.Left+$owner.Frame.Right)/2
                if (($Rtl -and $owner.Rail.Left -le $center) -or (-not $Rtl -and $owner.Rail.Right -ge $center)) { throw 'Actual rail is not on the required physical side.' }
                $content = [Windows.Automation.AutomationElement]::FromHandle([IntPtr][long]$app.Hwnd).FindAll(
                    [Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
                $term = @($content | Where-Object { $_.Current.ClassName -eq 'TermControl' -and -not $_.Current.IsOffscreen })
                if ($term.Count -ne 1 -or $term[0].Current.ProcessId -ne $app.Pid) { throw 'No unique mirrored content frame.' }
                $tb = $term[0].Current.BoundingRectangle
                Assert-SidebarTooltipRect $tb
                if (($Rtl -and $tb.Right -gt $owner.Rail.Left) -or (-not $Rtl -and $tb.Left -lt $owner.Rail.Right)) { throw 'Terminal content is not opposite the rail.' }
            }
            foreach ($required in @('Fixture line two', 'Fixture line three', 'Fixture line four', $titles[1], $owner.Shortcut)) {
                if (-not $required -or -not $owner.Help.Contains($required)) { throw 'Incomplete current owner HelpText.' }
            }
            $pointIndex = -1
            foreach ($point in $owner.Points) {
                $pointIndex++
                foreach ($neighbor in @(0, 2)) {
                    if ($script:scenarioClock.Elapsed.TotalSeconds -ge 240) { throw 'Scenario budget exhausted; remaining samples are unproven.' }
                    Set-WtPaneFocus -App $app -SessionId $identities[1].session_id | Out-Null
                    if (-not (Set-WtWindowForeground -App $app)) { throw 'Foreground unavailable.' }
                    Set-TooltipColdPointer $app (@(Get-TooltipRows $app $titles -Horizontal:$Horizontal -Collapsed:$Collapsed)[1])
                    if (@(Get-TooltipCandidates $app).Count) { throw 'Tooltip already present before controlled entry.' }
                    Assert-TooltipCanonical $app $titles $identities
                    Invoke-SidebarTooltipHover -App $app -Point $point -Peer $owner.Peer -Context @{
                        App=$app;Point=$point;Owner=$owner;Titles=$titles;Identities=$identities;PointIndex=$pointIndex;Neighbor=$neighbor
                        Horizontal=[bool]$Horizontal;Collapsed=[bool]$Collapsed;Rtl=[bool]$Rtl;ScreenFallback=[bool]$ScreenFallback
                        EvidencePath=$script:evidence
                    } -DuringHover {
                            param($sampleContext)
                            $app=$sampleContext.App;$point=$sampleContext.Point;$owner=$sampleContext.Owner
                            $titles=$sampleContext.Titles;$identities=$sampleContext.Identities
                            $pointIndex=$sampleContext.PointIndex;$neighbor=$sampleContext.Neighbor
                            $Horizontal=$sampleContext.Horizontal;$Collapsed=$sampleContext.Collapsed
                            $Rtl=$sampleContext.Rtl;$ScreenFallback=$sampleContext.ScreenFallback
                            $tip = Wait-TooltipOpen $app $owner $point @($titles[0], $titles[2])
                            $current = @(Get-TooltipRows $app $titles -Horizontal:$Horizontal -Collapsed:$Collapsed)
                            if ($current[1].RuntimeId -cne $owner.RuntimeId -or $current[1].Band.ToString() -cne $owner.Band.ToString()) { throw 'Stale owner geometry.' }
                            $screen = $null
                            if (-not $Horizontal) {
                                if (($tip.Bounds.Bottom - $tip.Bounds.Top) -le ($current[0].Band.Bottom - $current[0].Band.Top)) { throw 'Multiline tooltip is not tall enough.' }
                                $monitor = [TooltipMonitor]::Read([IntPtr][long]$app.Hwnd)
                                $screen = $monitor.Screen
                                Assert-SidebarTooltipRect $screen
                                $gap = if ($Rtl) { $owner.Band.Left-$tip.Bounds.Right } else { $tip.Bounds.Left-$owner.Band.Right }
                                $dpi = [TooltipMonitor]::GetDpiForWindow([IntPtr][long]$app.Hwnd)
                                if (-not $dpi) { throw 'Window DPI unavailable.' }
                                $room = if ($Rtl) { $owner.Band.Left-$screen.Left } else { $screen.Right-$owner.Band.Right }
                                if ($ScreenFallback) {
                                    $fit = Get-SidebarTooltipFit $owner.Band $tip.Bounds $screen -Rtl:$Rtl
                                    @{fit=$fit;screen=$screen;owner=$owner.Band;popup=$tip} | ConvertTo-Json -Depth 6 -Compress |
                                        Add-Content (Join-Path $script:evidence 'fallback.jsonl')
                                    if ($fit -ne 'FeasibleOpposite') { throw "Required feasible fallback not established: $fit (impossible fit never credits clearance)." }
                                    if ($tip.Bounds.Left -lt $screen.Left -or $tip.Bounds.Right -gt $screen.Right -or
                                        $tip.Bounds.Top -lt $screen.Top -or $tip.Bounds.Bottom -gt $screen.Bottom) { throw 'Native fallback clipped the actual popup.' }
                                }
                                elseif ($room -lt ($tip.Bounds.Right-$tip.Bounds.Left) -or
                                    $tip.Bounds.Top -lt $screen.Top -or $tip.Bounds.Bottom -gt $screen.Bottom) {
                                    throw 'No measured normal-space fit; constrained fallback is not core clearance.'
                                }
                                if (-not $ScreenFallback -and -not $Rtl -and $null -eq $script:nativeGapDip) {
                                    if ($gap -lt 0) { throw 'LTR native reference does not clear the whole owner.' }
                                    if ($gap -ge ($tip.Bounds.Right-$tip.Bounds.Left)) { throw 'Native reference has an extra-popup-width displacement.' }
                                    $script:nativeGapDip = $gap*96.0/$dpi
                                }
                                # Calibrate native automatic spacing from the first ample LTR sample,
                                # rather than treating a foreign-framework 20-DIP constant as UWP truth.
                                $envelope = $script:nativeGapDip*$dpi/96.0
                                if (-not $ScreenFallback) {
                                    if ($room -lt ($tip.Bounds.Right-$tip.Bounds.Left)+$envelope) { throw 'Core ample-room prerequisite unavailable; feasible fallback remains separate.' }
                                    if ($gap -lt 0 -or [math]::Abs($gap-$envelope) -gt 1) { throw 'Tooltip gap differs from measured native automatic spacing; no extra-width allowance.' }
                                }
                                foreach ($index in @(0, 2)) {
                                    if ((Get-SidebarTooltipIntersection $tip.Bounds $current[$index].Band) -ne 0) { throw 'Tooltip obstructs adjacent activation band.' }
                                }
                                $script:lastTipWidth = $tip.Bounds.Right-$tip.Bounds.Left
                            }
                            else {
                                $sample = [pscustomobject]@{
                                    Locale=$script:locale; PointIndex=$pointIndex; Neighbor=$neighbor; Text=$tip.Text
                                    Dpi=[TooltipMonitor]::GetDpiForWindow([IntPtr][long]$app.Hwnd); NativeHash=$script:nativeHash
                                    FrameWidth=$owner.Frame.Right-$owner.Frame.Left; FrameHeight=$owner.Frame.Bottom-$owner.Frame.Top
                                    Width=$tip.Bounds.Right-$tip.Bounds.Left; Height=$tip.Bounds.Bottom-$tip.Bounds.Top
                                    LeftFromOwner=$tip.Bounds.Left-$owner.Band.Left; TopFromOwner=$tip.Bounds.Top-$owner.Band.Top
                                    Popup=$tip; Owner=$owner.Band; Source=$env:ITE2E_SOURCE_COMMIT
                                    AppHash=$env:ITE2E_EXPECTED_APP_SHA256; InputReceipt=$script:localeInputReceipt.path
                                    InputReceiptSHA256=$script:localeInputReceipt.sha256; OriginalInputReceipt=$app.InputReceiptPath
                                    Pid=$app.Pid; RunToken=$app.InputRunToken; Hwnd=$app.Hwnd
                                }
                                if (-not $script:baselineMode) {
                                    $matches = @($script:baseline.samples | Where-Object {
                                        $_.Locale -eq $script:locale -and $_.PointIndex -eq $pointIndex -and $_.Neighbor -eq $neighbor
                                    })
                                    if ($matches.Count -ne 1) { throw 'No unique actual Horizontal baseline sample.' }
                                    Assert-SidebarTooltipBaseline $matches[0] $sample
                                }
                                $script:horizontalSamples.Add($sample)
                            }
                            @{
                                popup=$tip; owner=$owner.Band; localeRtl=[bool]$Rtl; horizontal=[bool]$Horizontal
                                physicalGap=$(if ($Rtl) { $owner.Band.Left - $tip.Bounds.Right } else { $tip.Bounds.Left - $owner.Band.Right })
                                hoverPoint=$point; collapsed=[bool]$Collapsed; monitorScreen=$screen; nativeSpacingDip=$script:nativeGapDip
                            } | ConvertTo-Json -Depth 6 -Compress | Add-Content (Join-Path $script:evidence 'hover.jsonl')
                            $click = $current[$neighbor].Points[1]
                            & (Get-Module ItE2E) { param($a,$x,$y,$peer)
                                [void](Get-ItOwnedPointerPeer -App $a -X $x -Y $y -ExpectedPeer $peer)
                            } $app $click.X $click.Y $current[$neighbor].Peer
                            if (-not [ItE2E.ItWtWin32Input]::SetCursorPos($click.X,$click.Y)) { throw 'Neighbor movement refused.' }
                            & (Get-Module ItE2E) { param($a,$x,$y,$peer)
                                [void](Get-ItOwnedPointerPeer -App $a -X $x -Y $y -ExpectedPeer $peer -ExpectedCursor @($x,$y))
                            } $app $click.X $click.Y $current[$neighbor].Peer
                            if (-not [ItE2E.ItWtWin32Input]::ClickOwnedPoint([IntPtr][long]$app.Hwnd, [uint32]$app.Pid, $click.X, $click.Y)) { throw 'Paired physical selection refused.' }
                            Wait-Until -TimeoutSec 5 -Because 'exact clicked shell identity' -Condition {
                                (Get-ActivePane -App $app).session_id -eq $identities[$neighbor].session_id
                            } | Out-Null
                            $context = Invoke-WtCli -App $app -Arguments @('get-pane-context','--target',$identities[$neighbor].session_id)
                            Assert-SidebarTooltipIdentity $identities[$neighbor] $context.pane
                            Assert-TooltipCanonical $app $titles $identities
                            $selected = @((Get-TooltipRows $app $titles -Horizontal:$Horizontal -Collapsed:$Collapsed) | Where-Object {
                                $pattern = $_.Peer.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)
                                $pattern.Current.IsSelected
                            })
                            if ($selected.Count -ne 1 -or $selected[0].RuntimeId -cne $current[$neighbor].RuntimeId) { throw 'Wrong canonical UIA selection.' }
                        }
                    Set-TooltipColdPointer $app (@(Get-TooltipRows $app $titles -Horizontal:$Horizontal -Collapsed:$Collapsed)[1])
                }
            }
        }
    }

    It 'Sidebar tooltips leave adjacent rows selectable' {
        $script:nativeGapDip = $null
        $script:CoreComplete = $false
        $coreContexts = 0
        foreach ($locale in @('en-US', 'ar-SA')) {
            $script:locale = $locale
            $app = $null; $launch = $null
            $originalCursor = $null
            $primaryFailure = $null
            $script:scenarioClock = [Diagnostics.Stopwatch]::StartNew()
            $dpi = [ItE2E.ItWtWin32Input]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
            if ($dpi -eq [IntPtr]::Zero) { throw 'Physical DPI context unavailable.' }
            try {
                $token = [guid]::NewGuid().ToString('N').Substring(0,8)
                $titles = @("tip-$token-A", "tip-$token-B", "tip-$token-C")
                $profiles = @(0..2 | ForEach-Object { @{
                    guid = '{' + [guid]::NewGuid().ToString() + '}'
                    name = $(if ($_ -eq 1) { "tip-$token-profile`nFixture line two`nFixture line three`nFixture line four" } else { "tip-$token-profile-$_" })
                    tabTitle=$titles[$_]; commandline='cmd.exe /d /k'; suppressApplicationTitle=$true; shellIntegrationEnabled=$false
                } })
                $fixture = (Resolve-Path (Join-Path $PSScriptRoot '..\fixtures\Mock-AcpInteractionAgent.ps1')).Path
                $code = "& '$($fixture.Replace("'", "''"))' -LogPath '$($script:evidence.Replace("'", "''"))\acp-$locale.log'"
                $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
                $launch = Get-Date
                $app = Start-Terminal -Package $script:package -TimeoutSec 60 -PassFre $true -State @{
                    sidebarLayoutMigrationCompleted=$true; sidebarIntroductionShown=$true
                } -Settings @{
                    language=$locale; tabLayout='vertical'; startupActions=''; firstWindowPreference='defaultProfile'
                    windowingBehavior='useNew'; 'warning.confirmOnClose'='never'; autoErrorDetectionEnabled=$false; autoFixEnabled=$false
                    defaultProfile=$profiles[0].guid; profiles=@{list=$profiles}; acpAgent="custom:tooltip-$token"
                    acpCustomCommand="`"$((Get-Command pwsh).Source)`" -NoProfile -EncodedCommand $encoded"
                }
                $loaded = @($app.OwnedProcess.Modules | Where-Object ModuleName -eq 'TerminalApp.dll')
                if ($loaded.Count -ne 1 -or $loaded[0].FileName -cne (Join-Path $script:target.InstallLocation 'TerminalApp.dll') -or
                    (Get-FileHash -LiteralPath $loaded[0].FileName).Hash -ne $env:ITE2E_EXPECTED_APP_SHA256) { throw 'Loaded exact-source App DLL not proven.' }
                @{
                    source=$env:ITE2E_SOURCE_COMMIT; package=$app.Package; pid=$app.Pid
                    loadedApp=$loaded[0].FileName; appHash=$env:ITE2E_EXPECTED_APP_SHA256; wtaHash=$env:ITE2E_EXPECTED_WTA_SHA256
                } | ConvertTo-Json | Set-Content (Join-Path $script:evidence "loaded-$locale.json")
                $originalCursor = [ItE2E.ItWtWin32Input]::GetCursorPosition()
                $script:localeInputReceipt = Save-SidebarTooltipInputReceipt $app.InputReceiptPath `
                    (Join-Path $script:evidence "input-receipt-$locale.jsonl") $app.Pid $app.InputRunToken $app.OwnedProcess.Path
                $created = @((Get-ActivePane -App $app))
                foreach ($index in @(1,2)) {
                    $created += Invoke-WtCli -App $app -Arguments @('new-tab','-p',$profiles[$index].guid,'-n',$titles[$index],'-w',[string]$app.WindowId)
                }
                $identities = @($created | ForEach-Object {
                    (Invoke-WtCli -App $app -Arguments @('get-pane-context','--target',$_.session_id)).pane
                })
                Assert-TooltipCanonical $app $titles $identities
                if (-not $script:baselineMode) {
                Assert-TooltipSample $app $titles $identities -Rtl:($locale -eq 'ar-SA')
                $coreContexts++
                $saved = [TooltipMonitor+PLACEMENT]::new()
                $saved.Length = [Runtime.InteropServices.Marshal]::SizeOf($saved)
                if (-not [TooltipMonitor]::GetWindowPlacement([IntPtr][long]$app.Hwnd,[ref]$saved)) { throw 'Cannot preserve owned placement.' }
                try {
                    $before = @(Get-TooltipRows $app $titles)[1]
                    $frame = $before.Frame
                    $screen = [TooltipMonitor]::Read([IntPtr][long]$app.Hwnd).Screen
                    $width = $frame.Right-$frame.Left
                    $changed = @{Left=$frame.Left;Top=$frame.Top;Right=$frame.Right;Bottom=$frame.Bottom}
                    $changed.Right = $changed.Left+[int]($width*0.8)
                    Set-TooltipOwnedFrame $app $changed $before
                    Wait-Until -TimeoutSec 5 -Because 'actual resized current owner' -Condition {
                        @(Get-TooltipRows $app $titles)[1].Frame.Width -ne $before.Frame.Width
                    } | Out-Null
                    Assert-TooltipSample $app $titles $identities -Rtl:($locale -eq 'ar-SA')
                    $now = @(Get-TooltipRows $app $titles)[1]
                    $desiredEdge = if ($locale -eq 'ar-SA') { $screen.Left+$script:lastTipWidth/2 } else { $screen.Right-$script:lastTipWidth/2 }
                    $edge = if ($locale -eq 'ar-SA') { $now.Band.Left } else { $now.Band.Right }
                    $delta = [int]($desiredEdge-$edge)
                    $moved = @{Left=$now.Frame.Left+$delta;Right=$now.Frame.Right+$delta;Top=$now.Frame.Top;Bottom=$now.Frame.Bottom}
                    Set-TooltipOwnedFrame $app $moved $now
                    $actual = @(Get-TooltipRows $app $titles)[1]
                    foreach ($r in @(Get-TooltipRows $app $titles)) {
                        if ($r.Band.Left -lt $screen.Left -or $r.Band.Right -gt $screen.Right) { throw 'Fallback owner/neighbor is not fully on screen.' }
                    }
                    Assert-TooltipSample $app $titles $identities -Rtl:($locale -eq 'ar-SA') -ScreenFallback
                }
                finally {
                    Set-TooltipColdPointer $app (@(Get-TooltipRows $app $titles)[1])
                    if ($app.OwnedProcess.HasExited -or [ItE2E.ItWtWin32Input]::GetWindowProcessId([IntPtr][long]$app.Hwnd) -ne $app.Pid -or
                        -not (Set-WtWindowForeground -App $app) -or
                        -not [TooltipMonitor]::SetWindowPlacement([IntPtr][long]$app.Hwnd,[ref]$saved)) { throw 'Owned placement recovery failed.' }
                    Wait-Until -TimeoutSec 5 -Because 'original physical owner frame restored' -Condition {
                        $restored = @(Get-TooltipRows $app $titles)[1].Frame
                        $same = $true
                        foreach ($edge in @('Left','Top','Right','Bottom')) {
                            if ([math]::Abs($restored.$edge-$frame.$edge) -gt 1) { $same=$false }
                        }
                        $same
                    } | Out-Null
                }
                $expanded = @(Get-TooltipRows $app $titles)[1].Rail
                Set-TooltipRailCollapsed $app
                Wait-Until -TimeoutSec 5 -Because 'actual compact rail width' -Condition {
                    $compact = @(Get-TooltipRows $app $titles -Collapsed)[1].Rail
                    ($compact.Right-$compact.Left) -lt ($expanded.Right-$expanded.Left)
                } | Out-Null
                Assert-TooltipSample $app $titles $identities -Collapsed -Rtl:($locale -eq 'ar-SA')
                $coreContexts++
                }
                Set-WtSetting -App $app -Key tabLayout -Value horizontal | Out-Null
                Wait-UiElement -App $app -Selector TabView -TimeoutSec 10 | Out-Null
                Assert-TooltipSample $app $titles $identities -Horizontal
            }
            catch { $primaryFailure = $_; throw }
            finally {
                Invoke-SidebarTooltipCheckedCleanup -PrimaryFailure $primaryFailure -Action @({
                    if ($app -and $originalCursor) {
                        $cursor = [ItE2E.ItWtWin32Input]::GetCursorPosition()
                        if ($cursor[0] -eq $originalCursor[0] -and $cursor[1] -eq $originalCursor[1]) { return }
                        & (Get-Module ItE2E) { param($a,$p)
                            [void](Get-ItOwnedPointerPeer -App $a -X $p[0] -Y $p[1] -ExpectedCursor $p)
                        } $app $cursor
                        if (-not [ItE2E.ItWtWin32Input]::SetCursorPos($originalCursor[0],$originalCursor[1])) { throw 'Cursor recovery failed.' }
                    }
                }, {
                    Stop-TestTerminal -App $app -Target $script:target -LaunchStarted $launch
                }, {
                    [void][ItE2E.ItWtWin32Input]::SetThreadDpiAwarenessContext($dpi)
                })
            }
        }
        if ($script:baselineMode) {
            @{
                sourceHead=$env:ITE2E_SOURCE_COMMIT; nativeHash=$script:nativeHash
                buildReceipt=(Join-Path $script:evidence 'build-receipt.json')
                buildReceiptSHA256=(Get-FileHash -LiteralPath (Join-Path $script:evidence 'build-receipt.json')).Hash
                samples=@($script:horizontalSamples.ToArray())
            } | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $script:evidence 'horizontal-baseline.json')
            throw 'Baseline diagnostic captured; intentionally no release credit.'
        }
        if ($coreContexts -ne 4 -or $script:horizontalSamples.Count -ne 12) { throw 'Incomplete mandatory matrix contexts.' }
        $script:CoreComplete = $true
        @{CoreComplete=$true; contexts=$coreContexts; matrixComplete=$true; liveAssertionsPassed=$true} | ConvertTo-Json |
            Set-Content (Join-Path $script:evidence 'core-complete.json')
    }
}
