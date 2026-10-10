#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }
# Runs the actual six-case suite with only external native prerequisites mocked.
$ErrorActionPreference = 'Stop'
$fixture = Join-Path $PSScriptRoot 'ResumeMetadataFixture.Unit.Tests.ps1'
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($fixture, [ref]$null, [ref]$errors)
if ($errors) { throw $errors }
$imports = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Import-Module'
}, $true))
if ($imports.Count -ne 1) { throw 'Expected exactly one shared module import in the actual fixture suite.' }
$source = Get-Content -LiteralPath $fixture -Raw
$insertion = $imports[0].Extent.EndOffset
$mocks = @'

        $script:realTestPath = Get-Command Test-Path -Module Microsoft.PowerShell.Management
        Mock Test-Path {
            if ($LiteralPath) { return (& $script:realTestPath -LiteralPath $LiteralPath) }
            return (& $script:realTestPath -Path $Path)
        }
        Mock Test-Path {
            if ('SCENARIO' -eq 'MissingVswhere' -and $LiteralPath.EndsWith('vswhere.exe')) { return $false }
            if ('SCENARIO' -eq 'MissingVcSetup' -and $LiteralPath.EndsWith('vcvars64.bat')) { return $false }
            return $true
        } -ParameterFilter {
            $LiteralPath -and ($LiteralPath.EndsWith('vswhere.exe') -or $LiteralPath.EndsWith('vcvars64.bat'))
        }
        Mock Invoke-Native {
            if ($FilePath.EndsWith('vswhere.exe')) {
                switch ('SCENARIO') {
                    'NoInstallation' { return @{ ExitCode = 0; TimedOut = $false; StdOut = ''; StdErr = '' } }
                    'DiscoveryFailure' { return @{ ExitCode = 9; TimedOut = $false; StdOut = ''; StdErr = 'injected discovery failure' } }
                    'DiscoveryTimeout' { return @{ ExitCode = 0; TimedOut = $true; StdOut = ''; StdErr = 'injected discovery timeout' } }
                    default { return @{ ExitCode = 0; TimedOut = $false; StdOut = $script:root; StdErr = '' } }
                }
            }
            if ($Arguments -contains '-EncodedCommand') {
                switch ('SCENARIO') {
                    'CompilerFailure' { return @{ ExitCode = 2; TimedOut = $false; StdOut = ''; StdErr = 'injected source compilation failure' } }
                    'CompilerTimeout' { return @{ ExitCode = 0; TimedOut = $true; StdOut = ''; StdErr = 'injected compiler timeout' } }
                }
            }
            throw "Unexpected native invocation: $FilePath"
        }
'@
$ownedRoot = Join-Path $PSScriptRoot ("..\artifacts\resume-prerequisites-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $ownedRoot | Out-Null
try {
foreach ($scenario in @('MissingVswhere', 'NoInstallation', 'MissingVcSetup',
        'DiscoveryFailure', 'DiscoveryTimeout', 'CompilerFailure', 'CompilerTimeout')) {
    $injected = $source.Insert($insertion, $mocks.Replace('SCENARIO', $scenario))
    # Preserve the real suite's relative paths when running its exact body from an owned file.
    $injected = $injected.Replace('$PSScriptRoot', "'$($PSScriptRoot.Replace("'", "''"))'")
    $injectedPath = Join-Path $ownedRoot "$scenario.Tests.ps1"
    Set-Content -LiteralPath $injectedPath -Value $injected -Encoding utf8
    $result = Invoke-Pester -Path $injectedPath -Output Detailed -PassThru
    $missing = $scenario -in @('MissingVswhere', 'NoInstallation', 'MissingVcSetup')
    $expectedSkipped = if ($missing) { 2 } else { 0 }
    $expectedFailed = if ($missing) { 0 } else { 2 }
    if ($result.PassedCount -ne 4 -or $result.SkippedCount -ne $expectedSkipped -or
        $result.FailedCount -ne $expectedFailed -or $result.TotalCount -ne 6) {
        throw "$scenario unexpected counts: passed=$($result.PassedCount), failed=$($result.FailedCount), skipped=$($result.SkippedCount), total=$($result.TotalCount)"
    }
    $native = @($result.Tests | Where-Object { $_.ExpandedName -like '*native shim holds*' -or $_.ExpandedName -like '*unreleased native gate*' })
    if ($native.Count -ne 2 -or @($native | Where-Object Result -ne $(if ($missing) { 'Skipped' } else { 'Failed' })).Count) {
        throw "$scenario did not isolate the two native gate cases."
    }
    Write-Host "VERIFIED $scenario`: 4 passed, $expectedFailed failed (expected), $expectedSkipped skipped."
}
}
finally { Remove-Item -LiteralPath $ownedRoot -Recurse -Force }
