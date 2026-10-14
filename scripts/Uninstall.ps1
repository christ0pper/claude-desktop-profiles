<#
.SYNOPSIS
    Removes a Claude Desktop profile's launcher and shortcuts, and optionally its data.
.PARAMETER Name
    The profile to remove.
.PARAMETER DeleteData
    Also delete the profile's data folder (its login, settings and local chat list). Asks first.
.PARAMETER Force
    With -DeleteData, delete without asking.
.EXAMPLE
    .\Uninstall.ps1 -Name Work
.EXAMPLE
    .\Uninstall.ps1 -Name Work -DeleteData
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [switch]$DeleteData,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'Common.ps1')

$root       = Get-CdpRoot
$profileDir = Get-CdpProfileDir $Name
$exeName    = "Claude $Name.exe"
$install    = $null
try { $install = Get-CdpInstall } catch { }
if ($install -and (Test-CdpProfileRunning $install $profileDir)) { throw "Quit 'Claude $Name' (system tray > Quit) first." }

$items = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) $exeName),
    (Join-Path ([Environment]::GetFolderPath('Programs')) "Claude $Name.lnk"),
    (Join-Path (Join-Path $root 'bin') $exeName),
    (Join-Path (Join-Path $root 'bin') "icons\$Name.ico")
)
foreach ($item in $items) {
    if ((Test-Path -LiteralPath $item) -and $PSCmdlet.ShouldProcess($item, 'Remove')) { Remove-Item -LiteralPath $item -Force }
}

if ($DeleteData -and (Test-Path -LiteralPath $profileDir)) {
    if ($Force -or $PSCmdlet.ShouldContinue("Delete '$profileDir'? This removes the profile's login, settings and local chat list.", "Delete profile '$Name'")) {
        Remove-Item -LiteralPath $profileDir -Recurse -Force
        Write-Host "Deleted $profileDir"
    }
} elseif (Test-Path -LiteralPath $profileDir) {
    Write-Host "Kept the profile's data in $profileDir (use -DeleteData to remove it)."
}
Write-Host "Removed profile '$Name' launchers." -ForegroundColor Green
