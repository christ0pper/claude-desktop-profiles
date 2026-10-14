<#
.SYNOPSIS
    Copies Claude Code (and Cowork) chat history from the default Claude app into a profile.
.DESCRIPTION
    Regular chats live on Anthropic's servers and appear in any app signed in to that account.
    Claude Code chats are listed from local files in the app's data folder, filed by account and
    organization, so a new profile starts with an empty list. This copies one account's session
    files into the profile. Files are copied, never moved, and existing files are never overwritten.
    The conversation transcripts themselves stay in %USERPROFILE%\.claude, which every profile shares.
.PARAMETER Name
    The profile to copy into.
.PARAMETER AccountId
    The account whose chats to copy. Defaults to the account the profile is signed in to.
.PARAMETER List
    Only show which accounts and organizations have chats, and where those chats worked.
.PARAMETER SourceDataDir
    Data folder to copy from. Defaults to the default Claude app's folder.
.EXAMPLE
    .\Copy-CodeSessions.ps1 -Name Work -List
.EXAMPLE
    .\Copy-CodeSessions.ps1 -Name Work -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$AccountId,
    [switch]$List,
    [string]$SourceDataDir
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'Common.ps1')

$profileDir = Get-CdpProfileDir $Name
if (-not (Test-Path -LiteralPath $profileDir)) { throw "Profile '$Name' does not exist." }
$install = $null
if (-not $SourceDataDir) { $install = Get-CdpInstall; $SourceDataDir = Join-Path $install.DataRoot 'Claude' }
$kinds = 'claude-code-sessions', 'local-agent-mode-sessions'
$profileAccount = Get-CdpAccountId $profileDir
$defaultAccount = Get-CdpAccountId $SourceDataDir

if ($List) {
    $codeRoot = Join-Path $SourceDataDir 'claude-code-sessions'
    if (-not (Test-Path -LiteralPath $codeRoot)) { Write-Host 'No Claude Code chats found.'; return }
    foreach ($acct in Get-ChildItem -LiteralPath $codeRoot -Directory) {
        $tags = @()
        if ($acct.Name -eq $defaultAccount) { $tags += 'default app' }
        if ($acct.Name -eq $profileAccount) { $tags += "profile '$Name'" }
        $label = if ($tags) { "  <- signed in to: $($tags -join ', ')" } else { '' }
        Write-Host "Account $($acct.Name)$label" -ForegroundColor Cyan
        foreach ($org in Get-ChildItem -LiteralPath $acct.FullName -Directory) {
            $files = @(Get-ChildItem -LiteralPath $org.FullName -Filter 'local_*.json' -Recurse)
            Write-Host ("  org {0}: {1} chats" -f $org.Name, $files.Count)
            $files | ForEach-Object { try { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).cwd } catch { } } |
                Where-Object { $_ } | Group-Object | Sort-Object Count -Descending | Select-Object -First 5 |
                ForEach-Object { Write-Host ("      {0,3} in {1}" -f $_.Count, $_.Name) }
        }
    }
    return
}

if (-not $AccountId) { $AccountId = $profileAccount }
if (-not $AccountId) { throw "Profile '$Name' is not signed in yet. Sign it in first, or pass -AccountId (see -List)." }
if ($AccountId -notmatch '^[0-9a-fA-F-]{36}$') { throw "'$AccountId' is not an account ID. Use -List to see them." }
if ($install -and (Test-CdpProfileRunning $install $profileDir)) { throw "Quit 'Claude $Name' (system tray > Quit) before copying." }

$copied = 0
foreach ($kind in $kinds) {
    $src = Join-Path (Join-Path $SourceDataDir $kind) $AccountId
    if (-not (Test-Path -LiteralPath $src)) { continue }
    $dst = Join-Path (Join-Path $profileDir $kind) $AccountId
    foreach ($file in Get-ChildItem -LiteralPath $src -File -Recurse) {
        $target = Join-Path $dst $file.FullName.Substring($src.Length).TrimStart('\')
        if (Test-Path -LiteralPath $target) { continue }
        if ($PSCmdlet.ShouldProcess($target, 'Copy chat file')) {
            New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $target
            $copied++
        }
    }
}
$chats = @(Get-ChildItem -LiteralPath (Join-Path (Join-Path $profileDir 'claude-code-sessions') $AccountId) -Filter 'local_*.json' -Recurse -ErrorAction SilentlyContinue).Count
Write-Host "Copied $copied file(s). Profile '$Name' now has $chats Claude Code chat(s) for account $AccountId." -ForegroundColor Green
if ($AccountId -ne $profileAccount) { Write-Host "Note: '$Name' is signed in to a different account, so these chats only show after signing it in to $AccountId." -ForegroundColor Yellow }
