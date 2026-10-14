<#
.SYNOPSIS
    Puts the default Claude profile back if a profile sign-in was interrupted.
.DESCRIPTION
    SignIn.ps1 temporarily parks the default profile as 'Claude.default-profile'. It restores it
    when it finishes, and the launcher calls this script automatically if that never happened.
    Exit codes: 0 = restored or nothing to do, 2 = quit Claude first, 3 = unexpected state (nothing changed).
#>
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'Common.ps1')

$code = Restore-CdpDefaultProfile (Get-CdpInstall)
switch ($code) {
    0 { Write-Host 'Default Claude profile is in place.' }
    2 { Write-Host 'Quit Claude from the system tray (right-click > Quit), then run this again.' -ForegroundColor Yellow }
    3 { Write-Host "Found both 'Claude' and 'Claude.default-profile' as real folders. Nothing was changed; please check them manually." -ForegroundColor Red }
}
exit $code
