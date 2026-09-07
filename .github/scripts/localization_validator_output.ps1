Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LocalizationValidatorSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JsonlPath
    )

    if (-not (Test-Path -LiteralPath $JsonlPath)) {
        throw [System.IO.FileNotFoundException]::new("Localization validator output file '$JsonlPath' was not found.")
    }

    $summary = Get-Content -LiteralPath $JsonlPath | Select-Object -Last 1 | ConvertFrom-Json -AsHashtable
    if ($summary.kind -ne 'summary') {
        throw 'Localization validator did not emit a summary record.'
    }

    return $summary
}

function Resolve-LocalizationValidatorCompletion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JsonlPath,
        [Parameter(Mandatory)][int]$ExitCode,
        [int[]]$AllowedExitCodes = @(0, 10, 20, 30, 64)
    )

    if ($AllowedExitCodes -notcontains $ExitCode) {
        throw "Unexpected localization validator exit code: $ExitCode"
    }

    $summary = Get-LocalizationValidatorSummary -JsonlPath $JsonlPath
    if ($ExitCode -eq 64) {
        if ($summary.status -ne 'BLOCKED' -or $summary.action -ne 'ESCALATE') {
            throw 'Localization validator exit 64 must emit a BLOCKED/ESCALATE summary record.'
        }
    }

    $shouldRun = if ($summary.action -eq 'ESCALATE') {
        $false
    } elseif ($null -ne $summary.should_run) {
        [bool]$summary.should_run
    } else {
        $false
    }

    return [pscustomobject]@{
        Summary = $summary
        ShouldRun = $shouldRun
    }
}
