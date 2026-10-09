BeforeAll {
    $script:suite = Join-Path $PSScriptRoot '..\tests\Feature.SidebarRowAlignment.Tests.ps1'
    $tokens = $null
    $errors = $null
    $script:ast = [Management.Automation.Language.Parser]::ParseFile($script:suite, [ref]$tokens, [ref]$errors)
    $script:parseErrors = $errors
    $script:title = 'Sidebar live and recent titles align'
    $script:root = Join-Path $PSScriptRoot ('..\artifacts\row-alignment-selftest-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:root | Out-Null
    $function = $script:ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-AlignmentDelta'
    }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
    $markerFunction = $script:ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-AlignmentMarker'
    }, $true)
    . ([scriptblock]::Create($markerFunction.Extent.Text))
    function Get-AlignmentChecklistBaseline {
        param([string]$BaseRef = $env:ITE2E_CHECKLIST_BASE_REF)
        if ([string]::IsNullOrEmpty($BaseRef)) { $BaseRef = 'origin/main' }
        $repo = Join-Path $PSScriptRoot '..\..\..'
        $commit = @(& git -C $repo rev-parse --verify --end-of-options "$BaseRef^{commit}" 2>$null)
        if ($LASTEXITCODE -ne 0 -or $commit.Count -ne 1) {
            throw "Cannot resolve checklist base '$BaseRef'; fetch the actual PR target or set ITE2E_CHECKLIST_BASE_REF."
        }
        $mergeBase = @(& git -C $repo merge-base --all HEAD $commit[0] 2>$null)
        if ($LASTEXITCODE -ne 0 -or $mergeBase.Count -ne 1) {
            throw "Cannot identify one checklist merge-base with '$BaseRef'."
        }
        $head = @(& git -C $repo rev-parse --verify HEAD 2>$null)
        if ($LASTEXITCODE -ne 0 -or $head.Count -ne 1 -or $mergeBase[0] -eq $head[0]) {
            throw "Checklist baseline must precede candidate HEAD; verify ITE2E_CHECKLIST_BASE_REF ('$BaseRef')."
        }
        $content = @(& git -C $repo show "$($mergeBase[0]):doc/release-check-list.md" 2>$null)
        if ($LASTEXITCODE -ne 0) { throw "Cannot read checklist baseline at $($mergeBase[0])." }
        $rows = @($content | Where-Object { $_ -match '^- \[[ x]\] `C\d+`' })
        if (-not $rows.Count) { throw "Checklist baseline at $($mergeBase[0]) contains no stable-ID rows." }
        Write-Host "Checklist baseline: $BaseRef -> merge-base $($mergeBase[0]); $($rows.Count) prior rows."
        $rows
    }
    function Assert-AlignmentChecklistPreserved {
        param([string[]]$Candidate, [string[]]$Baseline)
        $baselineCounts = @{}
        $candidateCounts = @{}
        foreach ($pair in @(@($Baseline, $baselineCounts), @($Candidate, $candidateCounts))) {
            foreach ($line in $pair[0]) {
                if ($line -match '^- \[[ x]\] `(?<id>C\d+)`') {
                    $id = $Matches.id
                    $pair[1][$id] = [int]$pair[1][$id] + 1
                }
            }
        }
        if (-not $baselineCounts.Count) { throw 'An independent nonempty checklist baseline is required.' }
        foreach ($id in $baselineCounts.Keys) {
            if ([int]$candidateCounts[$id] -ne $baselineCounts[$id]) {
                throw "Prior checklist ID occurrence count changed: $id (expected $($baselineCounts[$id]), actual $([int]$candidateCounts[$id]))."
            }
        }
    }
    function New-AlignmentResult {
        param([string]$Result)
        $path = Join-Path $script:root "$Result.xml"
        $executed = if ($Result -eq 'Ignored') { 'False' } else { 'True' }
        '<test-results><test-suite><results><test-case name="Feature: Sidebar row alignment.' +
            $script:title + '" executed="' + $executed + '" result="' + $Result +
            '" /></results></test-suite></test-results>' | Set-Content -LiteralPath $path
        $path
    }
}
AfterAll { Remove-Item -LiteralPath $script:root -Recurse -Force }

Describe 'Sidebar row alignment nonlive contracts' -Tag Unit {
    It 'reuses a validated run-scoped marker for matched baseline and candidate titles' {
        $marker = 'row-align-20261009-a1b2c3'
        Resolve-AlignmentMarker $marker | Should -Be $marker
        Resolve-AlignmentMarker $marker | Should -Be (Resolve-AlignmentMarker $marker)
        Resolve-AlignmentMarker '' | Should -Match '^row-align-[a-f0-9]{8}$'
        foreach ($invalid in @('short', '../baseline', 'row align fixture', 'fixture_123', '-fixture-123',
            "fixture-123`n", ('a' * 65))) {
            { Resolve-AlignmentMarker $invalid } | Should -Throw
        }
        $script:ast.Extent.Text | Should -Match 'Resolve-AlignmentMarker \$env:ITE2E_ALIGNMENT_MARKER'
        $script:ast.Extent.Text | Should -Match '\$script:liveTitle = "\$script:marker-live"'
        $script:ast.Extent.Text | Should -Match '\$script:historyTitle = "\$script:marker-history"'
        $script:ast.Extent.Text | Should -Match 'if \(Test-Path -LiteralPath \$script:evidence\)'
        $script:ast.Extent.Text | Should -Match 'Alignment evidence already exists'
    }
    It 'persists actual geometry and screenshot before the unchanged baseline-failing oracle' {
        $case = $script:ast.Find({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'It'
        }, $true)
        $commands = @($case.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst]
        }, $true))
        $geometry = @($commands | Where-Object {
            $_.GetCommandName() -eq 'Set-Content' -and $_.Extent.Text.Contains("'geometry.json'")
        })
        $screenshot = @($commands | Where-Object {
            $_.GetCommandName() -eq 'Save-UiScreenshot' -and $_.Extent.Text.Contains("'alignment.png'")
        })
        $firstOracle = @($commands | Where-Object { $_.GetCommandName() -eq 'Assert-AlignmentDelta' })[0]
        $geometry | Should -HaveCount 1
        $screenshot | Should -HaveCount 1
        $geometry[0].Extent.EndOffset | Should -BeLessThan $firstOracle.Extent.StartOffset
        $screenshot[0].Extent.EndOffset | Should -BeLessThan $firstOracle.Extent.StartOffset
        $case.Extent.Text | Should -Match 'title_delta_dip'
        $case.Extent.Text | Should -Match 'fixture_marker'
        $case.Extent.Text | Should -Match 'icon_center_delta_dip'
        $case.Extent.Text | Should -Not -Match 'if.*baseline|ExpectedFailure|Set-ItResult|Set-ItResult -Skipped'
        { Assert-AlignmentDelta 50 40 1 } | Should -Throw
    }
    It 'parses one exact-title real-package case without forbidden fixture setup' {
        $script:parseErrors | Should -BeNullOrEmpty
        $cases = @($script:ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'It'
        }, $true))
        $cases | Should -HaveCount 1
        $cases[0].CommandElements[1].Value | Should -Be $script:title
        $script:ast.Extent.Text | Should -Not -Match 'Clear-WtConfig|Set-WtSetting|Start-Terminal|Stop-Terminal|HistoryList|HistorySearchTextBox|CombinedAgentsSidebar|Uninstall|Stop-Process'
        foreach ($required in @('ItemsList', 'SearchTextBox', 'Get-FreCompleted', 'ITE2E_SOURCE_COMMIT',
            'ITE2E_EXPECTED_APP_SHA256', 'ITE2E_EXPECTED_WTA_SHA256', 'Backup-WtConfig',
            'Invoke-SidebarSessionCleanup', 'OwnedPaneIds', 'original-hashes.json', 'runtime-cleanup.json',
            'Emit-SidebarSessionHooks.ps1', 'Read-AlignmentSessions', 'SelectionItemPattern',
            'icon_geometry_verified', 'pending independent review')) {
            $script:ast.Extent.Text | Should -Match ([regex]::Escape($required))
        }
    }
    It 'detects the pre-fix ten-DIP title and six-DIP icon deltas at multiple DPI scales' {
        foreach ($scale in @(1.0, 1.25, 1.5, 2.0)) {
            { Assert-AlignmentDelta (50 * $scale) (40 * $scale) $scale } | Should -Throw
            { Assert-AlignmentDelta (26 * $scale) (20 * $scale) $scale } | Should -Throw
            { Assert-AlignmentDelta (50 * $scale) (50 * $scale) $scale } | Should -Not -Throw
            { Assert-AlignmentDelta (50 * $scale) (49 * $scale) $scale } | Should -Not -Throw
            { Assert-AlignmentDelta (50 * $scale) (48.9 * $scale) $scale } | Should -Throw
        }
        { Assert-AlignmentDelta 50 50 0 } | Should -Throw
    }
    It 'uses one viewport origin and never substitutes slot geometry for missing icon peers' {
        $text = $script:ast.Extent.Text
        $text | Should -Match 'liveTitle.Current.BoundingRectangle.Left - \$viewport.Left'
        $text | Should -Match 'recentTitle.Current.BoundingRectangle.Left - \$viewport.Left'
        $text | Should -Match 'RawViewWalker'
        $text | Should -Match 'if \(\$iconsVerified\)'
        $text | Should -Match 'else \{ Write-Warning \$receipt.icon_limitation \}'
        $text | Should -Not -Match 'icon.*=.*(?:26|18)\s*\*'
        $text | Should -Match 'Get-FileHash -LiteralPath \$script:target.SettingsPath'
    }
    It 'allocates one stable exact-title ID and preserves prior checklist ID occurrence counts' {
        $path = Join-Path $PSScriptRoot '..\..\..\doc\release-check-list.md'
        $lines = @(Get-Content -LiteralPath $path)
        $matched = @($lines | Where-Object { $_.Contains("**$($script:title):") })
        $matched | Should -HaveCount 1
        $matched[0] | Should -Match '^- \[ \] `C\d+`.*`\[E2E\]`'
        $matched[0] -match '`(?<id>C\d+)`' | Should -BeTrue
        $id = $Matches.id
        @($lines | Where-Object { $_.Contains('`' + $id + '`') }) | Should -HaveCount 1
        $baseline = @(Get-AlignmentChecklistBaseline)
        Assert-AlignmentChecklistPreserved -Candidate $lines -Baseline $baseline
    }
    It 'rejects in-memory committed removal and ID replacement against the independent PR base' {
        $baseline = @(Get-AlignmentChecklistBaseline)
        $candidate = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\..\doc\release-check-list.md'))
        $prior = $baseline[0]
        $prior | Should -Match '`C\d+`'
        $index = [Array]::IndexOf($candidate, $prior)
        $index | Should -BeGreaterOrEqual 0
        $removed = @(for ($i = 0; $i -lt $candidate.Count; $i++) { if ($i -ne $index) { $candidate[$i] } })
        { Assert-AlignmentChecklistPreserved -Candidate $removed -Baseline $baseline } |
            Should -Throw '*Prior checklist ID occurrence count changed*'
        $replacement = $prior -replace '`C\d+`', '`C999999`'
        $changed = @($candidate)
        $changed[$index] = $replacement
        { Assert-AlignmentChecklistPreserved -Candidate $changed -Baseline $baseline } |
            Should -Throw '*Prior checklist ID occurrence count changed*'
        $wording = @($candidate)
        $wording[$index] = ($prior -replace '^- \[[ x]\]', '- [x]') + ' Updated wording.'
        { Assert-AlignmentChecklistPreserved -Candidate $wording -Baseline $baseline } | Should -Not -Throw
        { Assert-AlignmentChecklistPreserved -Candidate $candidate -Baseline @() } |
            Should -Throw '*nonempty checklist baseline*'
    }
    It 'counts repeated prior IDs rather than treating checklist preservation as set membership' {
        $prior = @('- [ ] `C001` First item', '- [ ] `C001` Second item')
        { Assert-AlignmentChecklistPreserved -Candidate $prior[0] -Baseline $prior } |
            Should -Throw '*expected 2, actual 1*'
        { Assert-AlignmentChecklistPreserved -Candidate ($prior + $prior[0]) -Baseline $prior } |
            Should -Throw '*expected 2, actual 3*'
        { Assert-AlignmentChecklistPreserved -Candidate ($prior + '- [ ] `C002` New item') -Baseline $prior } |
            Should -Not -Throw
    }
    It 'refuses a missing or candidate-HEAD baseline rather than silently passing' {
        { Get-AlignmentChecklistBaseline -BaseRef 'refs/heads/ite2e-nonexistent-checklist-base' } |
            Should -Throw '*Cannot resolve checklist base*'
        { Get-AlignmentChecklistBaseline -BaseRef HEAD } |
            Should -Throw '*baseline must precede candidate HEAD*'
    }
    It 'maps synthetic success to full and incremental reports without claiming live acceptance' {
        $xml = New-AlignmentResult Success
        $full = Join-Path $script:root 'full.md'
        $incremental = Join-Path $script:root 'incremental.md'
        & (Join-Path $PSScriptRoot '..\New-ReleaseReport.ps1') -ResultsXml $xml -OutFile $full
        & (Join-Path $PSScriptRoot '..\New-ReleaseReport.ps1') -ResultsXml @() -OutFile $incremental
        & (Join-Path $PSScriptRoot '..\Update-ReleaseReport.ps1') -Report $incremental -ResultsXml $xml -OutFile $incremental
        foreach ($path in @($full, $incremental)) {
            Get-Content -LiteralPath $path -Raw |
                Should -Match ('(?m)^- \[x\].*\*\*' + [regex]::Escape($script:title) + ':')
        }
    }
    It 'retains a genuine failed mapping through a skipped-only incremental overlay' {
        $failed = New-AlignmentResult Failure
        $skipped = New-AlignmentResult Ignored
        $report = Join-Path $script:root 'failed.md'
        & (Join-Path $PSScriptRoot '..\New-ReleaseReport.ps1') -ResultsXml $failed -OutFile $report
        $before = Get-Content -LiteralPath $report -Raw
        $before | Should -Match ('(?m)^- \[ \].*AUTOMATION FAILED.*\*\*' + [regex]::Escape($script:title) + ':')
        & (Join-Path $PSScriptRoot '..\Update-ReleaseReport.ps1') -Report $report -ResultsXml $skipped -OutFile $report
        $after = Get-Content -LiteralPath $report -Raw
        ($after -split "`n" | Where-Object { $_.Contains("**$($script:title):") }) |
            Should -Be ($before -split "`n" | Where-Object { $_.Contains("**$($script:title):") })
    }
}
