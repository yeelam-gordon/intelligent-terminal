function Select-SidebarTooltipDesktopRuntime {
    param([string[]]$RuntimeLines, [int]$ClrMajor)
    $compatible = @(
        foreach ($line in $RuntimeLines) {
            if ($line -match '^Microsoft\.WindowsDesktop\.App ([0-9]+\.[0-9]+\.[0-9]+) \[(.+)\]$') {
                $version = [version]$Matches[1]
                if ($version.Major -eq $ClrMajor) {
                    [pscustomobject]@{Version=$version;Path=(Join-Path $Matches[2] $Matches[1])}
                }
            }
        }
    )
    if (-not $compatible.Count) { throw "Windows Desktop runtime matching PowerShell CLR major $ClrMajor is not installed." }
    ($compatible | Sort-Object Version -Descending | Select-Object -First 1).Path
}

function Initialize-SidebarTooltipDesktop {
    $architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    $root = if ($architecture -eq 'X86') { ${env:ProgramFiles(x86)} } else { $env:ProgramFiles }
    $dotnet = Join-Path $root 'dotnet\dotnet.exe'
    if (-not (Test-Path -LiteralPath $dotnet -PathType Leaf)) { throw "Matching-architecture dotnet host unavailable: $dotnet" }
    $result = Invoke-Native -FilePath $dotnet -Arguments @('--list-runtimes') -TimeoutSec 10
    if ($result.ExitCode -ne 0 -or $result.TimedOut) { throw 'Bounded dotnet Desktop runtime discovery failed.' }
    $path = Select-SidebarTooltipDesktopRuntime ($result.StdOut -split '\r?\n') ([Environment]::Version.Major)
    foreach ($name in @('WindowsBase','UIAutomationTypes','UIAutomationClient')) {
        $assembly = Join-Path $path "$name.dll"
        if (-not (Test-Path -LiteralPath $assembly -PathType Leaf)) { throw "Matching Desktop assembly missing: $assembly" }
        [void][Reflection.Assembly]::LoadFrom($assembly)
    }
    $path
}

function Assert-SidebarTooltipRect {
    param($Rect)
    if (-not $Rect) { throw 'Missing physical rectangle.' }
    foreach ($key in @('Left', 'Top', 'Right', 'Bottom')) {
        $value = $Rect.$key
        if ($null -eq $value -or -not [double]::IsFinite([double]$value)) {
            throw "Invalid physical rectangle: $key"
        }

    }
    if ($Rect.Right -le $Rect.Left -or $Rect.Bottom -le $Rect.Top) {
        throw 'Empty or inverted physical rectangle.'
    }
}

function Invoke-SidebarTooltipHover {
    param($App, $Point, $Peer, $Context, [Parameter(Mandatory)][scriptblock]$DuringHover)
    $module = Get-Module ItE2E
    if (-not $module) { throw 'ItE2E must be loaded for guarded hover.' }
    $inspect = { param($a,$x,$y,$peer,$context,$focused) Write-SidebarTooltipHoverObservation $a $x $y $peer $context $focused }
    & $module {
        param($a, [int]$x, [int]$y, $peer, $context, [scriptblock]$observer, [scriptblock]$inspect)
        $focused = Set-WtWindowForeground -App $a
        & $inspect $a $x $y $peer $context $focused
        if (-not $focused) { throw 'Owned hover foreground acquisition failed.' }
        $callback = { & $observer $context }.GetNewClosure()
        Invoke-ItOwnedPointer -App $a -FromX $x -FromY $y -ToX $x -ToY $y `
            -ExpectedPeer $peer -HoverMs 100 -DuringHover $callback
    } $App $Point.X $Point.Y $Peer $Context $DuringHover $inspect
}

function Write-SidebarTooltipHoverObservation {
    param($App,[int]$X,[int]$Y,$Peer,$Context,[bool]$Focused)
    $root=[IntPtr][long]$App.Hwnd
    $point=[ItE2E.ItWtWin32Input+POINT]::new();$point.X=$X;$point.Y=$Y
    $hit=[ItE2E.ItWtWin32Input]::WindowFromPoint($point)
    $ancestor=[ItE2E.ItWtWin32Input]::GetAncestor($hit,2)
    $foreground=[ItE2E.ItWtWin32Input]::GetForegroundWindow()
    $rootPid=[ItE2E.ItWtWin32Input]::GetWindowProcessId($root)
    $hitPid=[ItE2E.ItWtWin32Input]::GetWindowProcessId($hit)
    $owned=$rootPid -eq $App.Pid -and $hitPid -eq $App.Pid -and $ancestor -eq $root -and $foreground -eq $root
    $data=@{stage='before-private-hover';pid=$App.Pid;hwnd=$root.ToInt64();point=@{X=$X;Y=$Y}
        focused=$Focused;foreground=$foreground.ToInt64();rootPid=$rootPid;nativeHit=$hit.ToInt64()
        nativeAncestor=$ancestor.ToInt64();nativePid=$hitPid;nativeOwned=$owned;expectedBand=$Context.Owner.Band}
    try {
        if ($Peer.Current.ProcessId -ne $App.Pid) {throw 'Expected header peer is not owned.'}
        $data.expected=@{type=$Peer.Current.ControlType.ProgrammaticName;class=$Peer.Current.ClassName
            runtimeId=($Peer.GetRuntimeId()-join ',');nativeHandle=$Peer.Current.NativeWindowHandle;pid=$Peer.Current.ProcessId}
        if ($owned -and $Focused) {
            $actual=[Windows.Automation.AutomationElement]::FromPoint([Windows.Point]::new($X,$Y))
            if ($actual.Current.ProcessId -ne $App.Pid) {throw 'Point ownership changed after native check; foreign peer metadata refused.'}
            $data.actual=@{type=$actual.Current.ControlType.ProgrammaticName;class=$actual.Current.ClassName
                runtimeId=($actual.GetRuntimeId()-join ',');nativeHandle=$actual.Current.NativeWindowHandle;pid=$actual.Current.ProcessId}
        }
    }
    finally {
        if (-not $Context.EvidencePath) {throw 'Hover observation requires an owned evidence destination.'}
        $data | ConvertTo-Json -Depth 6 -Compress | Add-Content (Join-Path $Context.EvidencePath 'header-point.jsonl')
    }
    if (-not $owned) {throw 'Native target/foreground ownership refused before UIA point probe.'}
}

function Assert-SidebarTooltipCommands {
    param([string]$SuitePath)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($SuitePath,[ref]$tokens,[ref]$errors)
    if ($errors) { throw 'Tooltip suite syntax prevents semantic preflight.' }
    $local=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object Name)
    $private=@('Initialize-WtWin32Input','Get-ItOwnedPointerPeer','Invoke-ItOwnedPointer')
    $module=Get-Module ItE2E
    if (-not $module) { throw 'ItE2E module missing at semantic preflight.' }
    & $module {param($names) foreach($name in $names){[void](Get-Command $name -CommandType Function -ErrorAction Stop)}} $private
    $names=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true) |
        ForEach-Object {$_.GetCommandName()} | Where-Object {$_} | Select-Object -Unique)
    foreach($name in $names) {
        if ($name -in $private -or $name -in $local) {continue}
        [void](Get-Command $name -ErrorAction Stop)
    }
}

function Invoke-SidebarTooltipCheckedCleanup {
    param($PrimaryFailure, [Parameter(Mandatory)][scriptblock[]]$Action)
    $failures = [Collections.Generic.List[object]]::new()
    foreach ($cleanup in $Action) {
        try { & $cleanup }
        catch { $failures.Add($_) }
    }
    if ($failures.Count) {
        if (-not $PrimaryFailure -and $failures.Count -eq 1) { throw $failures[0] }
        $exceptions = [Collections.Generic.List[Exception]]::new()
        if ($PrimaryFailure) { $exceptions.Add($PrimaryFailure.Exception) }
        foreach ($failure in $failures) { $exceptions.Add($failure.Exception) }
        throw [AggregateException]::new('Original tooltip failure and independent cleanup failures.', $exceptions.ToArray())
    }
}

function Invoke-SidebarTooltipColdExit {
    param([int]$TipCount, [long]$OwnedRoot, [long]$CursorRoot, [int]$CursorPid, [int]$OwnerPid,
        $TargetRect, $CursorPoint, [bool]$LeaseOwned, [bool]$OwnerFullyVisible,
        [Parameter(Mandatory)][scriptblock]$Move)
    if ($TargetRect) {
        Assert-SidebarTooltipRect $TargetRect
        foreach ($coordinate in @('X','Y')) {
            if ($null -eq $CursorPoint.$coordinate -or -not [double]::IsFinite([double]$CursorPoint.$coordinate)) {
                throw 'Invalid physical cursor point for cold owner association.'
            }
        }
        $inside = $CursorPoint.X -ge $TargetRect.Left -and $CursorPoint.X -le $TargetRect.Right -and
            $CursorPoint.Y -ge $TargetRect.Top -and $CursorPoint.Y -le $TargetRect.Bottom
        if ($LeaseOwned -and $OwnerFullyVisible -and $TipCount -eq 0 -and $OwnedRoot -ne 0 -and
            $CursorRoot -eq $OwnedRoot -and $CursorPid -eq $OwnerPid -and -not $inside) {
            return 'AlreadyColdOutsideOwner'
        }
    }
    if ($LeaseOwned -and $TipCount -eq 0 -and $OwnedRoot -ne 0 -and $CursorRoot -ne 0 -and $CursorPid -gt 0 -and
        ($CursorRoot -ne $OwnedRoot -or $CursorPid -ne $OwnerPid)) { return 'AlreadyColdOutside' }
    & $Move
    'ControlledExit'
}

function Get-SidebarTooltipIntersection {
    param($First, $Second)
    Assert-SidebarTooltipRect $First
    Assert-SidebarTooltipRect $Second
    $width = [math]::Max(0.0, [math]::Min([double]$First.Right, [double]$Second.Right) - [math]::Max([double]$First.Left, [double]$Second.Left))
    $height = [math]::Max(0.0, [math]::Min([double]$First.Bottom, [double]$Second.Bottom) - [math]::Max([double]$First.Top, [double]$Second.Top))
    $width * $height
}

function Get-SidebarTooltipPoints {
    param($Band, $Actions)
    Assert-SidebarTooltipRect $Band
    $y = [int][math]::Floor(($Band.Top + $Band.Bottom) / 2)
    $safe = @(
        for ($x = [int][math]::Ceiling($Band.Left + 2); $x -le [math]::Floor($Band.Right - 2); $x++) {
            $blocked = $false
            foreach ($action in $Actions) {
                Assert-SidebarTooltipRect $action
                if ($x -ge $action.Left - 2 -and $x -le $action.Right + 2 -and
                    $y -ge $action.Top - 2 -and $y -le $action.Bottom + 2) { $blocked = $true }
            }
            if (-not $blocked) { $x }
        }
    )
    if ($safe.Count -lt 3) { throw 'Three distinct safe physical hover points unavailable.' }
    $middle = $safe | Sort-Object { [math]::Abs($_ - ($Band.Left + $Band.Right) / 2) } | Select-Object -First 1
    $xs = @($safe[0], $middle, $safe[-1])
    if (@($xs | Select-Object -Unique).Count -ne 3) { throw 'Hover points are not distinct.' }
    @($xs | ForEach-Object { [pscustomobject]@{ X = $_; Y = $y } })
}

function Select-SidebarTooltip {
    param($Candidates, [int]$OwnerPid, [string]$ExpectedText, [string[]]$ForeignTitles)
    $unique = @{}
    foreach ($candidate in $Candidates) {
        if (-not $candidate.RuntimeId -or $candidate.Pid -ne $OwnerPid -or $candidate.Offscreen) {
            throw 'Foreign, stale or invisible tooltip candidate.'
        }
        Assert-SidebarTooltipRect $candidate.Bounds
        if ($unique.ContainsKey($candidate.RuntimeId)) {
            if (($unique[$candidate.RuntimeId] | ConvertTo-Json -Depth 5 -Compress) -cne
                ($candidate | ConvertTo-Json -Depth 5 -Compress)) { throw 'Conflicting current tooltip runtime identity.' }
            continue
        }
        $unique[$candidate.RuntimeId] = $candidate
    }
    if ($unique.Count -ne 1) { throw 'Expected exactly one owned outer ToolTip.' }
    $tip = @($unique.Values)[0]
    if (($tip.Text -replace "`r`n", "`n") -cne ($ExpectedText -replace "`r`n", "`n")) {
        throw 'Tooltip content does not match current owner HelpText.'
    }
    foreach ($title in $ForeignTitles) {
        if ($tip.Text.Contains($title)) { throw 'Tooltip contains a foreign tab title.' }
    }
    $tip
}

function Assert-SidebarTooltipStable {
    param($Previous, $Current)
    if ($Previous.RuntimeId -cne $Current.RuntimeId) { throw 'Tooltip runtime identity changed.' }
    foreach ($key in @('Left', 'Top', 'Right', 'Bottom')) {
        if ([math]::Abs($Previous.Bounds.$key - $Current.Bounds.$key) -gt 1) {
            throw 'Tooltip geometry has not settled.'
        }
    }
}

function Assert-SidebarTooltipIdentity {
    param($Expected, $Actual)
    foreach ($key in @('session_id', 'tab_id', 'window_id')) {
        if ($null -eq $Expected.$key -or [string]$Expected.$key -cne [string]$Actual.$key) {
            throw "Wrong selected protocol identity: $key"
        }
    }
}

function Get-SidebarTooltipFit {
    param($Rail, $Tip, $Screen, [switch]$Rtl)
    foreach ($rect in @($Rail, $Tip, $Screen)) { Assert-SidebarTooltipRect $rect }
    $width = $Tip.Right - $Tip.Left
    $left = $Rail.Left - $Screen.Left
    $right = $Screen.Right - $Rail.Right
    $inward = if ($Rtl) { $left } else { $right }
    $opposite = if ($Rtl) { $right } else { $left }
    if ($inward -ge $width + 2) { return 'Ample' }
    if ($opposite -ge $width + 2) { return 'FeasibleOpposite' }
    'ImpossibleLateralFit'
}

function ConvertTo-SidebarTooltipFixtureText {
    param([string]$Text)
    $Text -replace 'tip-[0-9a-f]{8}-(profile(?:-[02])?|[ABC])(?=$|[\s\n])', 'tip-fixture-$1'
}

function Assert-SidebarTooltipBaseline {
    param($Baseline, $Current)
    foreach ($key in @('Locale','PointIndex','Neighbor','Dpi','NativeHash','FrameWidth','FrameHeight')) {
        if ([string]$Baseline.$key -cne [string]$Current.$key) { throw "Horizontal baseline mismatch: $key" }
    }
    if ((ConvertTo-SidebarTooltipFixtureText $Baseline.Text) -cne (ConvertTo-SidebarTooltipFixtureText $Current.Text)) {
        throw 'Horizontal baseline content changed beyond controlled fixture tokens.'
    }
    foreach ($key in @('Width','Height','LeftFromOwner','TopFromOwner')) {
        if ($null -eq $Baseline.$key -or $null -eq $Current.$key -or
            -not [double]::IsFinite([double]$Baseline.$key) -or -not [double]::IsFinite([double]$Current.$key) -or
            [math]::Abs([double]$Baseline.$key-[double]$Current.$key) -gt 1) {
            throw "Horizontal actual popup geometry changed: $key"
        }
    }
}

function Assert-SidebarTooltipWttResult {
    param([string]$Path, [string]$Selector, [int]$RunnerPid)
    [xml]$xml = Get-Content -LiteralPath $Path -Raw
    if ($xml.DocumentElement.LocalName -cne 'WTT-Logger') { throw 'Unsupported native WTT root.' }
    $title = "TerminalAppLocalTests::TabTests::$Selector"
    $tests = @($xml.SelectNodes('//EndTest') | Where-Object { $_.GetAttribute('Title') -ceq $title })
    if ($tests.Count -ne 1 -or $tests[0].GetAttribute('Result') -cne 'Passed') {
        throw "Required executed WTT EndTest is not uniquely Passed: $Selector"
    }
    $trace = @($tests[0].SelectNodes('Data/WexTraceInfo'))
    if ($RunnerPid -le 0 -or $trace.Count -ne 1 -or $trace[0].GetAttribute('ProcessId') -cne [string]$RunnerPid) {
        throw 'WTT EndTest does not match the recorded TE runner identity.'
    }
}

function Assert-SidebarTooltipWttReceipt {
    param($Receipt)
    if (@($Receipt.resultsFiles).Count -ne 2 -or -not $Receipt.runtimeResultsPath -or -not $Receipt.runtimeResultsSHA256 -or
        -not $Receipt.hostPackageFamilyName -or
        (Get-FileHash -LiteralPath $Receipt.runtimeResultsPath).Hash -ne $Receipt.runtimeResultsSHA256) {
        throw 'Missing or mismatched actual WTT runtime provenance packet.'
    }
    if (-not $Receipt.recoveryPath -or -not $Receipt.recoverySHA256 -or -not $Receipt.sourceDiffSHA256 -or
        (Get-FileHash -LiteralPath $Receipt.recoveryPath).Hash -ne $Receipt.recoverySHA256) { throw 'Native cleanup/source snapshot receipt missing.' }
    $recovery = Get-Content $Receipt.recoveryPath -Raw | ConvertFrom-Json
    if ($recovery.Equal -isnot [bool] -or $recovery.Equal -ne $true -or
        $recovery.HEAD -cne $Receipt.sourceHead.Substring(0,40) -or
        $recovery.BeforeTrackedDiffSHA256 -ne $Receipt.sourceDiffSHA256 -or
        $recovery.AfterTrackedDiffSHA256 -ne $Receipt.sourceDiffSHA256 -or
        $null -eq $recovery.OwnedPackageRemaining -or $recovery.OwnedPackageRemaining -ne 0 -or
        $null -eq $recovery.OwnedHostPids -or @($recovery.OwnedHostPids).Count -ne 0) {
        throw 'Native source snapshot changed or owned host/package cleanup is unproven.'
    }
    $runs = @(Get-Content $Receipt.runtimeResultsPath -Raw | ConvertFrom-Json)
    foreach ($selector in @('VerticalTabTooltipsTrackOwnerGeometry','VerticalTabTooltipsExposeStableShortcuts')) {
        $files = @($Receipt.resultsFiles | Where-Object selector -ceq $selector)
        $matched = @($runs | Where-Object Target -ceq $selector)
        if ($files.Count -ne 1 -or $matched.Count -ne 1 -or -not $files[0].path -or -not $files[0].sha256 -or
            (Get-FileHash -LiteralPath $files[0].path).Hash -ne $files[0].sha256) { throw "WTT result missing/duplicated/hash mismatch: $selector" }
        $run = $matched[0]
        if ($null -eq $run.Exit -or $run.Exit -ne 0 -or $run.TimedOut -isnot [bool] -or $run.TimedOut -ne $false -or
            $run.RunnerPid -le 0 -or @($run.Hosts).Count -ne 1) { throw 'Native runner failed, timed out or lacks a unique created host.' }
        $host = $run.Hosts[0]
        $created = [datetimeoffset]::MinValue
        if ($host.Pid -le 0 -or $host.PackageFamilyName -cne $Receipt.hostPackageFamilyName -or
            -not [datetimeoffset]::TryParse([string]$host.Created,[ref]$created)) { throw 'Native package-host creation identity missing.' }
        foreach ($name in @('TestHostApp.exe','TerminalApp.dll','TerminalApp.LocalTests.dll')) {
            $modules = @($host.Modules | Where-Object Name -ceq $name)
            if ($modules.Count -ne 1 -or -not $modules[0].Path -or -not $modules[0].SHA256 -or
                (Get-FileHash -LiteralPath $modules[0].Path).Hash -ne $modules[0].SHA256) { throw "Native loaded module evidence mismatch: $name" }
            if (($name -eq 'TerminalApp.dll' -and $modules[0].SHA256 -ne $Receipt.appSHA256) -or
                ($name -eq 'TerminalApp.LocalTests.dll' -and ($modules[0].SHA256 -ne $Receipt.testDllSHA256 -or
                    [IO.Path]::GetFullPath($modules[0].Path) -cne [IO.Path]::GetFullPath($Receipt.testDllPath))) -or
                ($name -eq 'TestHostApp.exe' -and [IO.Path]::GetFullPath($modules[0].Path) -cne [IO.Path]::GetFullPath($host.Path))) {
                throw 'Native loaded App/test/host differs from receipt identity.'
            }
        }
        Assert-SidebarTooltipWttResult $files[0].path $selector $run.RunnerPid
    }
}

function Assert-SidebarTooltipNativeReceipt {
    param($Receipt, [string]$Source, [string]$AppHash)
    if ($Receipt.sourceHead -cne $Source -or $Receipt.appSHA256 -ne $AppHash -or
        $Receipt.hosted -isnot [bool] -or $Receipt.hosted -ne $true) {
        throw 'Native lifecycle receipt is not hosted at the candidate source/App hash.'
    }

    if ($Receipt.resultsFiles) {
        if (-not $Receipt.testDllPath -or -not $Receipt.testDllSHA256 -or
            (Get-FileHash -LiteralPath $Receipt.testDllPath).Hash -ne $Receipt.testDllSHA256) { throw 'Native test DLL hash mismatch.' }
        Assert-SidebarTooltipWttReceipt $Receipt
        return
    }
    foreach ($pair in @(@($Receipt.testDllPath,$Receipt.testDllSHA256), @($Receipt.resultsXml,$Receipt.resultsSHA256))) {
        if (-not $pair[0] -or -not $pair[1] -or (Get-FileHash -LiteralPath $pair[0]).Hash -ne $pair[1]) {
            throw 'Native lifecycle result/DLL evidence mismatch.'
        }
    }
    [xml]$xml = Get-Content -LiteralPath $Receipt.resultsXml -Raw
    $schema = $xml.DocumentElement.LocalName
    if ($schema -notin @('test-results','test-run')) { throw 'Unsupported native result schema; actual TAEF evidence adapter required.' }
    foreach ($selector in @('VerticalTabTooltipsTrackOwnerGeometry','VerticalTabTooltipsExposeStableShortcuts')) {
        $cases = @($xml.SelectNodes('//test-case') | Where-Object { $_.name -match "(?:^|::|\.)$selector$" })
        if ($cases.Count -ne 1) { throw "Required native selector is missing or duplicated: $selector" }
        $case = $cases[0]
        if ($schema -eq 'test-results') {
            $passed = $case.GetAttribute('result') -ceq 'Success' -and $case.GetAttribute('executed') -ceq 'True'
        }
        else {
            $duration = 0.0
            $passed = $case.GetAttribute('result') -ceq 'Passed' -and
                [double]::TryParse($case.GetAttribute('duration'), [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$duration) -and
                [double]::IsFinite($duration) -and $duration -ge 0
            if ($case.HasAttribute('executed') -and $case.GetAttribute('executed') -cne 'True') { $passed = $false }
        }
        if (-not $passed) {
            throw "Required hosted native lifecycle selector is not passed: $selector"
        }
    }
}

function Assert-SidebarTooltipInputReceipt {
    param($Proof, [int]$OwnerPid, [string]$RunToken, [string]$Image)
    if ($OwnerPid -le 0 -or -not $RunToken -or -not $Image -or -not $Proof.path -or -not $Proof.sha256 -or
        (Get-FileHash -LiteralPath $Proof.path).Hash -ne $Proof.sha256) { throw 'Owned input receipt hash/identity mismatch.' }
    $records = @(Get-Content -LiteralPath $Proof.path | ForEach-Object { $_ | ConvertFrom-Json })
    if (@($records | Where-Object { $_.pid -eq $OwnerPid -and $_.run_token -ceq $RunToken -and
        $_.path -ceq $Image }).Count -ne 1) { throw 'Owned input receipt has no unique real creation record.' }
}

function Save-SidebarTooltipInputReceipt {
    param([string]$Path, [string]$Destination, [int]$OwnerPid, [string]$RunToken, [string]$Image)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $stream = [IO.File]::Open($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length) }
    finally { $stream.Dispose() }
    $proof = @{path=$Destination;sha256=(Get-FileHash -LiteralPath $Destination).Hash}
    Assert-SidebarTooltipInputReceipt $proof $OwnerPid $RunToken $Image
    [IO.File]::SetAttributes($Destination,[IO.FileAttributes]::ReadOnly)
    $proof
}

function Assert-SidebarTooltipArchive {
        param([string]$Path, [string]$Sha256, $Entries)
        if (-not $Path -or -not $Sha256 -or (Get-FileHash -LiteralPath $Path).Hash -ne $Sha256) {
            throw 'Original MSIX archive hash mismatch.'
        }
        $archive = [IO.Compression.ZipFile]::OpenRead($Path)
        try {
            foreach ($expected in $Entries) {
                $matches = @($archive.Entries | Where-Object { $_.FullName -ceq $expected.file })
                if ($matches.Count -ne 1 -or $matches[0].Length -le 0) { throw "Missing/ambiguous original MSIX entry: $($expected.file)" }
                $stream = $matches[0].Open()
                $sha = [Security.Cryptography.SHA256]::Create()
                try { $actual = [Convert]::ToHexString($sha.ComputeHash($stream)) }
                finally { $sha.Dispose(); $stream.Dispose() }
                if ($actual -ne $expected.hash -or (Get-FileHash -LiteralPath $expected.installed).Hash -ne $expected.hash) {
                    throw "Original archive/immutable installed payload mismatch: $($expected.file)"
                }
            }
        }
        finally { $archive.Dispose() }
    }

    function Assert-SidebarTooltipOriginalArchive {
        param($Receipt)
        $proof = $Receipt.baselineOriginalMsix
        $source = $Receipt.sourceHead
        $archiveHash = $proof.sha256
        if ($source -notmatch '^[0-9a-fA-F]{40}(?:[+ ].*)?$' -or -not $Receipt.installedIdentity.PFN -or
            -not $proof -or $archiveHash -notmatch '^[0-9a-fA-F]{64}$' -or
            -not $proof.registerReceiptPath -or -not $proof.registerReceiptSHA256 -or
            (Get-FileHash -LiteralPath $proof.registerReceiptPath).Hash -ne $proof.registerReceiptSHA256) {
            throw 'Original source/private identity/archive registration evidence missing or mismatched.'
        }
        $registration = Get-Content -LiteralPath $proof.registerReceiptPath -Raw | ConvertFrom-Json
        if ($registration.SourceHead -cne $source -or $registration.Identity.PFN -cne $Receipt.installedIdentity.PFN -or
            $registration.MsixSHA256 -ne $archiveHash -or
            [IO.Path]::GetFullPath($registration.ImmutableMsix) -cne [IO.Path]::GetFullPath($proof.path)) {
            throw 'Archive is not linked to the authentic original source registration receipt.'
        }
        $entries = @(
            foreach ($file in @('TerminalApp.dll','wta.exe')) {
                $entry = @($Receipt.hashes | Where-Object file -eq $file)
                $registered = @($registration.Hashes | Where-Object File -eq $file)
                if ($entry.Count -ne 1 -or $registered.Count -ne 1 -or -not $entry[0].corresponding -or
                    $entry[0].hash -ne $registered[0].SHA256 -or
                    [IO.Path]::GetFullPath($entry[0].installed) -cne [IO.Path]::GetFullPath($registered[0].PackagedPath)) {
                    throw "Original build/registration payload correspondence mismatch: $file"
                }
                $entry[0]
            }
        )
        Assert-SidebarTooltipArchive $proof.path $archiveHash $entries
    }
