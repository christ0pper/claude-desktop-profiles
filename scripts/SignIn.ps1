<#
.SYNOPSIS
    Signs a Claude Desktop profile in to an account.
.DESCRIPTION
    Claude Desktop signs in through your web browser, which hands the result back with a claude://
    link. Windows always delivers that link to the default Claude app, never to a profile, so a
    profile cannot finish signing in on its own.

    This script works around that: it parks the default profile, points the default app at the
    chosen profile with a directory junction, opens Claude so you can sign in, and puts everything
    back when you quit Claude. If the script is interrupted, the launcher (or Restore.ps1) restores
    the default profile the next time it runs. Your data is moved and renamed, never deleted.
.PARAMETER Name
    The profile to sign in, e.g. Work.
.PARAMETER TimeoutMinutes
    How long to wait for each step before giving up (default 30).
.EXAMPLE
    .\SignIn.ps1 -Name Work
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [int]$TimeoutMinutes = 30
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'Common.ps1')

function Say([string]$Text, [string]$Color = 'Gray') { Write-Host $Text -ForegroundColor $Color }

function Wait-Until([scriptblock]$Condition, [string]$What) {
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while (-not (& $Condition)) {
        if ((Get-Date) -gt $deadline) { throw "Timed out after $TimeoutMinutes minutes waiting for: $What" }
        Start-Sleep -Seconds 1
    }
}

$profileDir = Get-CdpProfileDir $Name
if (-not (Test-Path -LiteralPath $profileDir)) { throw "Profile '$Name' does not exist. Create it first: install.ps1 -Name `"$Name`"" }
$install = Get-CdpInstall
$live    = Join-Path $install.DataRoot 'Claude'
$backup  = Join-Path $install.DataRoot $script:CdpBackupName

if (-not (Test-Path -LiteralPath $live)) {
    throw "Default Claude data folder not found at '$live'. Open Claude Desktop once normally, quit it, then try again."
}
if ((Restore-CdpDefaultProfile $install) -ne 0) {
    throw "An earlier sign-in left the default profile parked and it could not be restored. Quit Claude and run Restore.ps1."
}
$defaultAccount = Get-CdpAccountId $live

# 1. Everything that uses the default folder or this profile must be closed.
if ((Test-CdpDefaultRunning $install) -or (Test-CdpProfileRunning $install $profileDir)) {
    Say "Quit Claude from the system tray (right-click the Claude icon > Quit). Closing the window is not enough." Yellow
    Say "If 'Claude $Name' is open, quit that one too. Waiting..." Yellow
    Wait-Until { -not (Test-CdpDefaultRunning $install) -and -not (Test-CdpProfileRunning $install $profileDir) } 'Claude to quit'
}
Start-Sleep -Seconds 2

# 2. Park the default profile. Helpers such as chrome-native-host.exe can hold it open briefly.
$parked = $false
for ($i = 1; $i -le 10 -and -not $parked; $i++) {
    Stop-CdpDataHelpers $install
    try { Rename-Item -LiteralPath $live -NewName $script:CdpBackupName; $parked = $true }
    catch { Start-Sleep -Seconds 1 }
}
if (-not $parked) { throw "Could not move '$live' (a program is still using it). Nothing was changed." }

try {
    New-Item -ItemType Junction -Path $live -Target $profileDir | Out-Null

    # 3. Open the default app, which now uses the profile, and let the user sign in.
    Say ''
    Say "Opening Claude with the '$Name' profile." Green
    Say '  Sign-in happens in your web browser and reuses whichever account the browser is signed in to.' Yellow
    Say "  If the browser shows the wrong account, sign out of claude.ai there (or pick the right Google account) first." Yellow
    Say '  When Claude shows the right account, quit it from the system tray (right-click > Quit).' Yellow
    Say ''
    if ($install.LaunchArgs) { Start-Process $install.LaunchTarget -ArgumentList $install.LaunchArgs } else { Start-Process $install.LaunchTarget }
    Wait-Until { Test-CdpDefaultRunning $install } 'Claude to start'
    Wait-Until { -not (Test-CdpDefaultRunning $install) } 'Claude to be quit after signing in'
    Start-Sleep -Seconds 2
}
finally {
    # Runs on success, errors and Ctrl+C. Only restore once nothing is using the folder.
    if (Test-CdpDefaultRunning $install) {
        Say 'Claude is still open, so the default profile was left parked. It is restored automatically the next time' Yellow
        Say "you open 'Claude $Name', or run Restore.ps1 after quitting Claude." Yellow
    } else {
        $code = Restore-CdpDefaultProfile $install
        if ($code -eq 0) { Say 'Default profile restored.' Green } else { Say "Could not restore the default profile (code $code). Run Restore.ps1." Red }
    }
}

# 4. Report which account the profile ended up with.
$profileAccount = Get-CdpAccountId $profileDir
if (-not $profileAccount) {
    Say "'$Name' is not signed in. Run this script again to retry." Yellow
} elseif ($profileAccount -eq $defaultAccount) {
    Say "Warning: '$Name' is signed in to the SAME account as your default Claude app." Yellow
    Say 'Your browser was probably still signed in to that account. Sign out of claude.ai in the browser and run this again.' Yellow
} else {
    Say "Done. '$Name' is signed in to its own account and will stay signed in. Open it with 'Claude $Name'." Green
}
