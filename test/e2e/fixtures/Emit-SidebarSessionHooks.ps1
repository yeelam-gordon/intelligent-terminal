param(
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$ReceiptPath,
    [Parameter(Mandatory)][string]$WtcliPath
)

$ErrorActionPreference = 'Stop'

function Write-SidebarHookReceipt {
    param(
        [Parameter(Mandatory)][string]$ReceiptPath,
        [Parameter(Mandatory)][int]$EventCount,
        [Parameter(Mandatory)][string]$PaneSessionId
    )
    $pendingPath = $ReceiptPath + '.' + [guid]::NewGuid().ToString('N') + '.pending'
    try {
        @{ events = $EventCount; pane_session_id = $PaneSessionId } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $pendingPath -ErrorAction Stop
        [IO.File]::Move($pendingPath, $ReceiptPath)
    }
    finally {
        if (Test-Path -LiteralPath $pendingPath) {
            Remove-Item -LiteralPath $pendingPath -ErrorAction Stop
        }
    }
}

if (-not $env:WT_SESSION -or -not $env:WT_COM_CLSID) {
    throw 'Sidebar hook fixtures must execute inside the selected Terminal shell pane.'
}

$events = @(Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json)
foreach ($entry in $events) {
    $entry.payload | ConvertTo-Json -Depth 8 -Compress |
        & $WtcliPath agent-hook --cli-source copilot --event $entry.event
    if ($LASTEXITCODE -ne 0) {
        throw "The $($entry.event) hook failed with exit code $LASTEXITCODE."
    }
}
Write-SidebarHookReceipt -ReceiptPath $ReceiptPath -EventCount $events.Count -PaneSessionId $env:WT_SESSION
