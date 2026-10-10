#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
Describe 'Sidebar tooltip physical oracle' -Tag Unit {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\tests\helpers\SidebarTooltipOracle.ps1')
        . (Join-Path $PSScriptRoot '..\tests\helpers\TestTerminalCleanup.ps1')
        Import-Module (Join-Path $PSScriptRoot '..\ItE2E\ItE2E.psd1') -Force
        function Get-TooltipUnitMarker { 'original suite context' }
        $script:tooltipUnitScope = 'suite script marker'
        function Rect($l, $t, $r, $b) { @{ Left=$l; Top=$t; Right=$r; Bottom=$b } }
        function Tip([string]$id = 'current', [int]$owner = 42, [string]$text = "profile`ntitle`nctrl+alt+2") {
            [pscustomobject]@{ RuntimeId=$id; Pid=$owner; Text=$text; Offscreen=$false; Bounds=(Rect 10 10 30 40) }
        }
    }
    It 'allows edge touch but rejects fractional positive overlap' {
        Get-SidebarTooltipIntersection (Rect -10 -10 0 10) (Rect 0 -10 10 10) | Should -Be 0
        Get-SidebarTooltipIntersection (Rect -10 -10 0.1 10) (Rect 0 -10 10 10) | Should -BeGreaterThan 0
    }
    It 'rejects missing, empty, inverted and nonfinite rectangles' {
        foreach ($r in @($null, (Rect 0 0 0 1), (Rect 2 0 1 1),
            (Rect ([double]::NaN) 0 1 1), (Rect 0 0 ([double]::PositiveInfinity) 1),
            @{Left=0; Top=0; Right=1})) {
            { Assert-SidebarTooltipRect $r } | Should -Throw
        }
    }
    It 'subtracts inflated actions and returns distinct physical points' {
        $points = @(Get-SidebarTooltipPoints (Rect 0 0 80 30) @((Rect 0 0 20 30), (Rect 60 0 80 30)))
        $points | Should -HaveCount 3
        $points[0].X | Should -BeGreaterThan 22
        $points[-1].X | Should -BeLessThan 58
        { Get-SidebarTooltipPoints (Rect 0 0 8 10) @((Rect 0 0 8 10)) } | Should -Throw
    }
    It 'deduplicates current outer runtime IDs without duplicating content' {
        $tip = Tip
        (Select-SidebarTooltip @($tip, $tip) 42 $tip.Text @('foreign')).RuntimeId | Should -Be current
    }
    It 'rejects absent, ambiguous, foreign and wrong-content popups' {
        $tip = Tip
        foreach ($c in @(@(), @($tip, (Tip other)), @((Tip current 43)), @((Tip current 42 stale)))) {
            { Select-SidebarTooltip $c 42 $tip.Text @('foreign') } | Should -Throw
        }
        { Select-SidebarTooltip @((Tip current 42 foreign)) 42 foreign @('foreign') } | Should -Throw
    }
    It 'rejects stale current identities and unsettled bounds' {
        $tip = Tip
        { Assert-SidebarTooltipStable $tip (Tip old) } | Should -Throw
        $changed = Tip; $changed.Bounds.Right = 33
        { Assert-SidebarTooltipStable $tip $changed } | Should -Throw
        { Assert-SidebarTooltipStable $tip $tip } | Should -Not -Throw
        $conflict = Tip; $conflict.Bounds.Right = 31
        { Select-SidebarTooltip @($tip, $conflict) 42 $tip.Text @() } | Should -Throw
    }
    It 'requires exact session tab and logical window rather than a title' {
        $expected = @{session_id='A'; tab_id=1; window_id=2}
        foreach ($actual in @(@{session_id='B';tab_id=1;window_id=2},
            @{session_id='A';tab_id=3;window_id=2}, @{session_id='A';tab_id=1;window_id=3})) {
            { Assert-SidebarTooltipIdentity $expected $actual } | Should -Throw
        }
        { Assert-SidebarTooltipIdentity $expected $expected } | Should -Not -Throw
    }
    It 'distinguishes ample opposite-side feasibility and impossible fit' {
        Get-SidebarTooltipFit (Rect 0 0 20 40) (Rect 20 0 50 40) (Rect -100 -100 100 100) | Should -Be Ample
        Get-SidebarTooltipFit (Rect 80 0 90 40) (Rect 20 0 50 40) (Rect 0 -100 100 100) | Should -Be FeasibleOpposite
        Get-SidebarTooltipFit (Rect 10 0 90 40) (Rect 20 0 50 40) (Rect 0 -100 100 100) | Should -Be ImpossibleLateralFit
    }
    It 'normalizes only controlled fixture tokens without stripping metadata' {
        ConvertTo-SidebarTooltipFixtureText "tip-1234abcd-profile`ntip-1234abcd-B`nctrl+alt+2" |
            Should -BeExactly "tip-fixture-profile`ntip-fixture-B`nctrl+alt+2"
        ConvertTo-SidebarTooltipFixtureText 'provider-session-1234abcd' | Should -BeExactly 'provider-session-1234abcd'
    }
    It 'compares actual horizontal baseline geometry and rejects mismatched native or text state' {
        $sample = @{Locale='ar-SA';PointIndex=1;Neighbor=0;Dpi=144;NativeHash='native';FrameWidth=1200;FrameHeight=900
            Text="tip-1234abcd-profile`ntip-1234abcd-B";Width=500;Height=150;LeftFromOwner=0;TopFromOwner=-150}
        $current = $sample.Clone();$current.Text="tip-abcdef12-profile`ntip-abcdef12-B"
        { Assert-SidebarTooltipBaseline $sample $current } | Should -Not -Throw
        foreach ($field in @('Locale','Dpi','NativeHash','Text','Width','TopFromOwner')) {
            $bad=$current.Clone();$bad[$field]=$(if ($field -in @('Dpi','Width','TopFromOwner')) {9999} else {'wrong'})
            { Assert-SidebarTooltipBaseline $sample $bad } | Should -Throw
        }
    }
    It 'requires real hashed native results with both executed passing selectors' {
        $dir=Join-Path $PSScriptRoot ('..\artifacts\tooltip-oracle-unit-'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $dir | Out-Null
        try {
            $dll=Join-Path $dir 'fixture.bin';$xml=Join-Path $dir 'results.xml'
            Set-Content $dll 'unit-only artifact'
            Set-Content $xml '<test-results><test-case name="TabTests::VerticalTabTooltipsTrackOwnerGeometry" result="Success" executed="True"/><test-case name="TabTests::VerticalTabTooltipsExposeStableShortcuts" result="Success" executed="True"/></test-results>'
            $receipt=@{sourceHead='source';appSHA256='app';hosted=$true;testDllPath=$dll;testDllSHA256=(Get-FileHash $dll).Hash
                resultsXml=$xml;resultsSHA256=(Get-FileHash $xml).Hash}
            { Assert-SidebarTooltipNativeReceipt $receipt source app } | Should -Not -Throw
            { Assert-SidebarTooltipNativeReceipt $receipt foreign app } | Should -Throw
            foreach ($hosted in @($false,$null,'false','true',1)) {
                $receipt.hosted=$hosted
                { Assert-SidebarTooltipNativeReceipt $receipt source app } | Should -Throw
            }
            $receipt.hosted=$true
            foreach ($executed in @('', ' executed="False"', ' executed="false"', ' executed="unknown"')) {
                Set-Content $xml "<test-results><test-case name=`"TabTests::VerticalTabTooltipsTrackOwnerGeometry`" result=`"Success`"$executed/><test-case name=`"TabTests::VerticalTabTooltipsExposeStableShortcuts`" result=`"Success`" executed=`"True`"/></test-results>"
                $receipt.resultsSHA256=(Get-FileHash $xml).Hash
                { Assert-SidebarTooltipNativeReceipt $receipt source app } | Should -Throw
            }
            Set-Content $xml '<test-run><test-case name="TabTests::VerticalTabTooltipsTrackOwnerGeometry" result="Passed" duration="0.1"/><test-case name="TabTests::VerticalTabTooltipsExposeStableShortcuts" result="Passed" duration="0.2"/></test-run>'
            $receipt.resultsSHA256=(Get-FileHash $xml).Hash
            { Assert-SidebarTooltipNativeReceipt $receipt source app } | Should -Not -Throw
            foreach ($duration in @('', ' duration="NaN"', ' duration="-1"', ' duration="invalid"')) {
                Set-Content $xml "<test-run><test-case name=`"TabTests::VerticalTabTooltipsTrackOwnerGeometry`" result=`"Passed`"$duration/><test-case name=`"TabTests::VerticalTabTooltipsExposeStableShortcuts`" result=`"Passed`" duration=`"0.2`"/></test-run>"
                $receipt.resultsSHA256=(Get-FileHash $xml).Hash
                { Assert-SidebarTooltipNativeReceipt $receipt source app } | Should -Throw
            }
            Set-Content $xml '<test-results><test-case name="TabTests::VerticalTabTooltipsTrackOwnerGeometry" result="Skipped" executed="False"/></test-results>'
            $receipt.resultsSHA256=(Get-FileHash $xml).Hash
            { Assert-SidebarTooltipNativeReceipt $receipt source app } | Should -Throw
        }
        finally { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
    It 'reads real archive entries and rejects changed archives installed bytes and missing entries' {
        $dir=Join-Path $PSScriptRoot ('..\artifacts\tooltip-archive-unit-'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $dir | Out-Null
        try {
            $path=Join-Path $dir 'unit.msix'
            $installed=Join-Path $dir 'TerminalApp.dll'
            [IO.File]::WriteAllBytes($installed,[Text.Encoding]::UTF8.GetBytes('unit payload'))
            $zip=[IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Create)
            try {
                $entry=$zip.CreateEntry('TerminalApp.dll');$stream=$entry.Open()
                try {$bytes=[IO.File]::ReadAllBytes($installed);$stream.Write($bytes,0,$bytes.Length)}
                finally {$stream.Dispose()}
            } finally {$zip.Dispose()}
            $hash=(Get-FileHash $path).Hash
            $entries=@(@{file='TerminalApp.dll';hash=(Get-FileHash $installed).Hash;installed=$installed})
            {Assert-SidebarTooltipArchive $path $hash $entries} | Should -Not -Throw
            {Assert-SidebarTooltipArchive $path ('0'*64) $entries} | Should -Throw
            {Assert-SidebarTooltipArchive $path $hash @(@{file='wta.exe';hash=$entries[0].hash;installed=$installed})} | Should -Throw
            [IO.File]::WriteAllText($installed,'changed installed payload')
            {Assert-SidebarTooltipArchive $path $hash $entries} | Should -Throw
            {Assert-SidebarTooltipOriginalArchive @{sourceHead='foreign'}} | Should -Throw
        } finally {Remove-Item -LiteralPath $dir -Recurse -Force}
    }
    It 'freezes first-launch real receipt bytes before a second launch appends to the shared ledger' {
        $dir=Join-Path $PSScriptRoot ('..\artifacts\tooltip-receipt-unit-'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $dir | Out-Null
        try {
            $shared=Join-Path $dir 'shared.jsonl'
            @{pid=101;run_token='run';path='Q:\fixture\WindowsTerminal.exe';start_utc='2026-10-10T00:00:00Z'} |
                ConvertTo-Json -Compress | Set-Content $shared
            $firstBytes=[IO.File]::ReadAllBytes($shared)
            $proof=Save-SidebarTooltipInputReceipt $shared (Join-Path $dir 'en-US.jsonl') 101 run 'Q:\fixture\WindowsTerminal.exe'
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($proof.path)) | Should -BeExactly ([Convert]::ToBase64String($firstBytes))
            $sharedFirst=@{path=$shared;sha256=$proof.sha256}
            @{pid=202;run_token='run';path='Q:\fixture\WindowsTerminal.exe';start_utc='2026-10-10T00:01:00Z'} |
                ConvertTo-Json -Compress | Add-Content $shared
            {Assert-SidebarTooltipInputReceipt $proof 101 run 'Q:\fixture\WindowsTerminal.exe'} | Should -Not -Throw
            {Assert-SidebarTooltipInputReceipt $sharedFirst 101 run 'Q:\fixture\WindowsTerminal.exe'} | Should -Throw
            $second=Save-SidebarTooltipInputReceipt $shared (Join-Path $dir 'ar-SA.jsonl') 202 run 'Q:\fixture\WindowsTerminal.exe'
            {Assert-SidebarTooltipInputReceipt $second 202 run 'Q:\fixture\WindowsTerminal.exe'} | Should -Not -Throw
            Add-Content $shared '{"later":"edit"}'
            {Assert-SidebarTooltipInputReceipt $proof 101 run 'Q:\fixture\WindowsTerminal.exe'} | Should -Not -Throw
            {Assert-SidebarTooltipInputReceipt $second 202 run 'Q:\fixture\WindowsTerminal.exe'} | Should -Not -Throw
        } finally {Remove-Item -LiteralPath $dir -Recurse -Force}
    }
    It 'preserves primary cursor and terminal cleanup failures while completing DPI recovery' {
        $primary=$null
        try {throw 'primary cold NativeHit'} catch {$primary=$_}
        $state=@{stop=$false;dpi=$false}
        $caught=$null
        try {
            Invoke-SidebarTooltipCheckedCleanup -PrimaryFailure $primary -Action @(
                {throw 'cursor cleanup NativeHit'},
                {$state.stop=$true;throw 'terminal cleanup'},
                {$state.dpi=$true}
            )
        } catch {$caught=$_}
        $caught.Exception | Should -BeOfType AggregateException
        $caught.Exception.InnerExceptions | Should -HaveCount 3
        $caught.Exception.InnerExceptions[0].Message | Should -BeExactly 'primary cold NativeHit'
        $caught.Exception.InnerExceptions[1].Message | Should -BeExactly 'cursor cleanup NativeHit'
        $caught.Exception.InnerExceptions[2].Message | Should -BeExactly 'terminal cleanup'
        $state.stop | Should -BeTrue
        $state.dpi | Should -BeTrue
        {Invoke-SidebarTooltipCheckedCleanup -Action {throw 'cleanup alone'}} | Should -Throw '*cleanup alone*'
    }
    It 'does not move input when tooltips are absent and the native cursor is outside the owned root' {
        $state=@{moves=0}
        Invoke-SidebarTooltipColdExit -TipCount 0 -OwnedRoot 100 -CursorRoot 200 -CursorPid 22 -OwnerPid 11 `
            -LeaseOwned $true -Move {$state.moves++} | Should -BeExactly AlreadyColdOutside
        $state.moves | Should -Be 0
        Invoke-SidebarTooltipColdExit -TipCount 1 -OwnedRoot 100 -CursorRoot 200 -CursorPid 22 -OwnerPid 11 `
            -Move {$state.moves++} | Should -BeExactly ControlledExit
        $state.moves | Should -Be 1
        {Invoke-SidebarTooltipColdExit -TipCount 0 -OwnedRoot 100 -CursorRoot 0 -CursorPid 0 -OwnerPid 11 `
            -Move {throw 'guarded movement refused'}} | Should -Throw '*guarded movement refused*'
    }
    It 'rejects copied authentic Fail WTT and only credits executed matching EndTest records' {
        $dir=Join-Path $PSScriptRoot ('..\artifacts\tooltip-wtt-unit-'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $dir | Out-Null
        try {
            $actual=Join-Path $PSScriptRoot '..\..\..\Generated Files\loop-gordon-release\sidebar-tooltip-placement\agents\private-native-testhost\output\VerticalTabTooltipsExposeStableShortcuts.wtl'
            $path=Join-Path $dir 'unit.wtl'
            if (Test-Path $actual) {
                Copy-Item -LiteralPath $actual -Destination $path
                {Assert-SidebarTooltipWttResult $path VerticalTabTooltipsExposeStableShortcuts 33912} | Should -Throw
            }
            $selector='VerticalTabTooltipsExposeStableShortcuts'
            foreach($body in @('<EndGroup Result="Passed"/>',
                "<EndTest Title=`"TerminalAppLocalTests::TabTests::$selector`" Result=`"Fail`"/>",
                "<EndTest Title=`"TerminalAppLocalTests::TabTests::$selector`" Result=`"Skipped`"/>",
                "<EndTest Title=`"TerminalAppLocalTests::TabTests::$selector`" Result=`"Error`"/>")) {
                [IO.File]::WriteAllText($path,"<WTT-Logger>$body</WTT-Logger>",[Text.Encoding]::Unicode)
                {Assert-SidebarTooltipWttResult $path $selector 123} | Should -Throw
            }
            $end="<EndTest Title=`"TerminalAppLocalTests::TabTests::$selector`" Result=`"Passed`"><Data><WexTraceInfo ProcessId=`"123`"/></Data></EndTest>"
            [IO.File]::WriteAllText($path,"<WTT-Logger>$end</WTT-Logger>",[Text.Encoding]::Unicode)
            {Assert-SidebarTooltipWttResult $path $selector 123} | Should -Not -Throw
            {Assert-SidebarTooltipWttResult $path $selector 456} | Should -Throw
            [IO.File]::WriteAllText($path,"<WTT-Logger>$end$end</WTT-Logger>",[Text.Encoding]::Unicode)
            {Assert-SidebarTooltipWttResult $path $selector 123} | Should -Throw
        } finally {Remove-Item -LiteralPath $dir -Recurse -Force}
    }
    It 'semantically resolves every suite command and its private helpers inside ItE2E' {
        Assert-SidebarTooltipCommands (Join-Path $PSScriptRoot '..\tests\Feature.SidebarTooltipPlacement.Tests.ps1')
        Get-Command Invoke-ItOwnedPointer -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
    It 'keeps an already cold cursor outside the intended owner still when inside the owned window' {
        $state=@{moves=0}
        $parameters=@{TipCount=0;OwnedRoot=100;CursorRoot=100;CursorPid=11;OwnerPid=11
            TargetRect=(Rect 10 10 100 40);CursorPoint=@{X=50;Y=200};LeaseOwned=$true;OwnerFullyVisible=$true}
        Invoke-SidebarTooltipColdExit @parameters -Move {$state.moves++} | Should -BeExactly AlreadyColdOutsideOwner
        $state.moves | Should -Be 0
        $parameters.CursorPoint=@{X=50;Y=20}
        Invoke-SidebarTooltipColdExit @parameters -Move {$state.moves++} | Should -BeExactly ControlledExit
        $state.moves | Should -Be 1
        $parameters.CursorPoint=@{X=50;Y=200};$parameters.TipCount=1
        Invoke-SidebarTooltipColdExit @parameters -Move {$state.moves++} | Should -BeExactly ControlledExit
        $state.moves | Should -Be 2
        $parameters.TipCount=0;$parameters.CursorRoot=0;$parameters.CursorPid=0
        {Invoke-SidebarTooltipColdExit @parameters -Move {throw 'unknown native guard refusal'}} | Should -Throw
        $parameters.CursorRoot=100;$parameters.CursorPid=11;$parameters.TargetRect=Rect 10 10 10 40
        {Invoke-SidebarTooltipColdExit @parameters -Move {$state.moves++}} | Should -Throw
        $state.moves | Should -Be 2
        $parameters.TargetRect=Rect 10 10 100 40;$parameters.OwnerFullyVisible=$false
        {Invoke-SidebarTooltipColdExit @parameters -Move {throw 'clipped owner guard refusal'}} | Should -Throw
        $parameters.OwnerFullyVisible=$true;$parameters.LeaseOwned=$false
        {Invoke-SidebarTooltipColdExit @parameters -Move {throw 'stale lease guard refusal'}} | Should -Throw
    }
    It 'invokes private hover inside ItE2E while preserving original suite callback context' {
        Mock Set-WtWindowForeground -ModuleName ItE2E {$true}
        Mock Write-SidebarTooltipHoverObservation {}
        Mock Invoke-ItOwnedPointer -ModuleName ItE2E {
            param($App,$FromX,$FromY,$ToX,$ToY,$ExpectedPeer,$HoverMs,$DuringHover)
            & $DuringHover
        }
        $state=@{Seen=$null}
        Invoke-SidebarTooltipHover -App @{id='owned'} -Point @{X=11;Y=22} -Peer 'current' -Context $state -DuringHover {
            param($context)
            $context.Seen=Get-TooltipUnitMarker
            $context.ScriptSeen=$script:tooltipUnitScope
        }
        $state.Seen | Should -BeExactly 'original suite context'
        $state.ScriptSeen | Should -BeExactly 'suite script marker'
        Should -Invoke Invoke-ItOwnedPointer -ModuleName ItE2E -Times 1 -Exactly -ParameterFilter {
            $App.id -eq 'owned' -and $FromX -eq 11 -and $ToX -eq 11 -and
            $FromY -eq 22 -and $ToY -eq 22 -and $ExpectedPeer -eq 'current' -and $HoverMs -eq 100
        }
        Should -Invoke Set-WtWindowForeground -ModuleName ItE2E -Times 1 -Exactly
        Should -Invoke Write-SidebarTooltipHoverObservation -Times 1 -Exactly -ParameterFilter {$Focused -eq $true}
    }
    It 'propagates the real private guard error without pretending callback success' {
        Mock Set-WtWindowForeground -ModuleName ItE2E {$true}
        Mock Write-SidebarTooltipHoverObservation {}
        Mock Invoke-ItOwnedPointer -ModuleName ItE2E {throw 'Owned pointer input refused: NativeHit'}
        $state=@{Seen=$false}
        {Invoke-SidebarTooltipHover -App @{} -Point @{X=11;Y=22} -Peer 'current' -Context $state -DuringHover {
            param($context)
            $context.Seen=$true
        }} | Should -Throw '*Owned pointer input refused: NativeHit*'
        $state.Seen | Should -BeFalse
    }
    It 'records failed owned focus before refusing private pointer invocation' {
        Mock Set-WtWindowForeground -ModuleName ItE2E {$false}
        Mock Write-SidebarTooltipHoverObservation {}
        Mock Invoke-ItOwnedPointer -ModuleName ItE2E {}
        {Invoke-SidebarTooltipHover -App @{} -Point @{X=11;Y=22} -Peer current -Context @{} -DuringHover {}} |
            Should -Throw '*foreground acquisition failed*'
        Should -Invoke Write-SidebarTooltipHoverObservation -Times 1 -Exactly -ParameterFilter {$Focused -eq $false}
        Should -Invoke Invoke-ItOwnedPointer -ModuleName ItE2E -Times 0
    }
    It 'accepts another explicitly verified baseline source and package without task-specific pins' {
        $dir=Join-Path $PSScriptRoot ('..\artifacts\tooltip-portable-unit-'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $dir | Out-Null
        try {
            $path=Join-Path $dir 'baseline.msix';$registrationPath=Join-Path $dir 'registration.json'
            $source='a'*40;$pfn='Unit.Baseline_fixture';$hashes=@();$registered=@()
            $zip=[IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach($name in @('TerminalApp.dll','wta.exe')) {
                    $installed=Join-Path $dir $name
                    [IO.File]::WriteAllText($installed,"unit-only $name")
                    $stream=$zip.CreateEntry($name).Open()
                    try {$bytes=[IO.File]::ReadAllBytes($installed);$stream.Write($bytes,0,$bytes.Length)}
                    finally {$stream.Dispose()}
                    $hash=(Get-FileHash $installed).Hash
                    $hashes+=@{file=$name;hash=$hash;installed=$installed;corresponding=$true}
                    $registered+=@{File=$name;SHA256=$hash;PackagedPath=$installed}
                }
            } finally {$zip.Dispose()}
            $archiveHash=(Get-FileHash $path).Hash
            @{SourceHead=$source;Identity=@{PFN=$pfn};ImmutableMsix=$path;MsixSHA256=$archiveHash;Hashes=$registered} |
                ConvertTo-Json -Depth 6 | Set-Content $registrationPath
            $receipt=@{sourceHead=$source;installedIdentity=@{PFN=$pfn};hashes=$hashes
                baselineOriginalMsix=@{path=$path;sha256=$archiveHash;registerReceiptPath=$registrationPath
                    registerReceiptSHA256=(Get-FileHash $registrationPath).Hash}}
            {Assert-SidebarTooltipOriginalArchive $receipt} | Should -Not -Throw
            $receipt.sourceHead='b'*40
            {Assert-SidebarTooltipOriginalArchive $receipt} | Should -Throw
        } finally {Remove-Item -LiteralPath $dir -Recurse -Force}
    }
}
