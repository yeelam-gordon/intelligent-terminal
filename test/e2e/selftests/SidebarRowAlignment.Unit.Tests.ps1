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
    It 'allocates one stable exact-title checklist ID and preserves existing IDs' {
        $path = Join-Path $PSScriptRoot '..\..\..\doc\release-check-list.md'
        $lines = @(Get-Content -LiteralPath $path)
        $matched = @($lines | Where-Object { $_.Contains("**$($script:title):") })
        $matched | Should -HaveCount 1
        $matched[0] | Should -Match '^- \[ \] `C\d+`.*`\[E2E\]`'
        $matched[0] -match '`(?<id>C\d+)`' | Should -BeTrue
        $id = $Matches.id
        @($lines | Where-Object { $_.Contains('`' + $id + '`') }) | Should -HaveCount 1
        $baseline = & git -C (Join-Path $PSScriptRoot '..\..\..') show HEAD:doc/release-check-list.md
        foreach ($line in $baseline) {
            if ($line -match '^- \[[ x]\] `C\d+`') { $lines | Should -Contain $line }
        }
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
