param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][ValidateSet('x64','ARM64')][string]$Arch
)
$ErrorActionPreference = 'Stop'

$buildOut = "src\cascadia\CascadiaPackage\AppPackages\CascadiaPackage_${Version}_${Arch}_Test"
$archLower = $Arch.ToLower()
$outDir = "artifacts\local-installer\agentic-terminal-${Version}-${archLower}-msix"
$refDir = "artifacts\local-installer\agentic-terminal-0.0.5.2-x64-msix"
$depSrc = "src\cascadia\CascadiaPackage\AppPackages\CascadiaPackage_0.0.5.2_${Arch}_Test\Dependencies\${archLower}\Microsoft.UI.Xaml.2.8.appx"

if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
New-Item -ItemType Directory -Path "$outDir\Dependencies" -Force | Out-Null

Copy-Item "$buildOut\CascadiaPackage_${Version}_${Arch}.msix" $outDir

if (Test-Path $depSrc) {
    Copy-Item $depSrc "$outDir\Dependencies\"
} else {
    Copy-Item "$refDir\Dependencies\Microsoft.UI.Xaml.2.8.appx" "$outDir\Dependencies\"
}

Copy-Item "$refDir\AgenticTerminalDev.cer" $outDir
Copy-Item "$refDir\Install.ps1" $outDir

$zip = "artifacts\local-installer\agentic-terminal-${Version}-${archLower}-msix.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path "$outDir\*" -DestinationPath $zip -Force

Write-Host "Created: $zip"
Get-Item $zip | Format-List Name, Length, LastWriteTime
Get-ChildItem $outDir -Recurse | Select-Object FullName, Length
