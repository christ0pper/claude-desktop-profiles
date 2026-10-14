# Claude Desktop Profiles - shared helpers. Dot-source this file; it only defines functions.
# Unofficial community tool; not affiliated with or endorsed by Anthropic.

$script:CdpStoreFamily = 'Claude_pzs8sxrjxfjjc'      # Microsoft Store package family (same on every PC)
$script:CdpBackupName  = 'Claude.default-profile'    # must match src\Launcher.cs
$script:CdpNamePattern = '^[A-Za-z0-9][A-Za-z0-9 _-]{0,39}$'

function Get-CdpRoot {
    if ($env:CLAUDE_PROFILES_ROOT) { return $env:CLAUDE_PROFILES_ROOT }
    Join-Path $env:USERPROFILE 'ClaudeProfiles'
}

function Assert-CdpProfileName([string]$Name) {
    if ($Name -notmatch $script:CdpNamePattern -or @('bin', 'default') -contains $Name.ToLowerInvariant()) {
        throw "Invalid profile name '$Name'. Use 1-40 letters, digits, spaces, '-' or '_' (and not 'bin' or 'default')."
    }
}

function Get-CdpProfileDir([string]$Name) {
    Assert-CdpProfileName $Name
    Join-Path (Get-CdpRoot) $Name
}

# Finds Claude Desktop. Returns Kind, Exe, InstallDir, DataRoot (parent of the default 'Claude' data folder)
# and LaunchTarget (what to start to open the default profile so it receives claude:// sign-in links).
function Get-CdpInstall {
    # Test hook: tests\Run-Tests.ps1 points this at a fake install in a temp folder.
    if ($env:CDP_TEST_INSTALL) { return $env:CDP_TEST_INSTALL | ConvertFrom-Json }
    $pkg =Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue |
        Where-Object { $_.PackageFamilyName -eq $script:CdpStoreFamily } | Select-Object -First 1
    if ($pkg) {
        $appId = 'Claude'
        try { $appId = (Get-AppxPackageManifest $pkg).Package.Applications.Application.Id | Select-Object -First 1 } catch { }
        return [pscustomobject]@{
            Kind         = 'Store'
            Exe          = Join-Path $pkg.InstallLocation 'app\claude.exe'
            InstallDir   = $pkg.InstallLocation
            DataRoot     = Join-Path $env:LOCALAPPDATA "Packages\$($script:CdpStoreFamily)\LocalCache\Roaming"
            LaunchTarget = "shell:AppsFolder\$($script:CdpStoreFamily)!$appId"
            LaunchArgs   = ''
        }
    }
    $classic = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
    if (Test-Path -LiteralPath (Join-Path $classic 'claude.exe')) {
        return [pscustomobject]@{
            Kind         = 'Installer'
            Exe          = Join-Path $classic 'claude.exe'
            InstallDir   = $classic
            DataRoot     = $env:APPDATA
            LaunchTarget = Join-Path $classic 'claude.exe'
            LaunchArgs   = ''
        }
    }
    throw 'Claude Desktop was not found. Install it from https://claude.ai/download first.'
}

function Get-CdpUserDataDir([string]$CommandLine) {
    if (-not $CommandLine) { return $null }
    foreach ($pattern in '"--user-data-dir=([^"]+)"', '--user-data-dir="([^"]+)"', '--user-data-dir=(\S+)') {
        if ($CommandLine -match $pattern) { return $Matches[1].TrimEnd('\') }
    }
    $null
}

# Claude Desktop processes started from this install. UserDataDir is $null for the default profile.
function Get-CdpDesktopProcesses($Install) {
    $prefix = $Install.InstallDir.TrimEnd('\') + '\'
    @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object {
            [pscustomobject]@{
                Id          = [int]$_.ProcessId
                UserDataDir = Get-CdpUserDataDir $_.CommandLine
                IsMain      = $_.CommandLine -notmatch '--type='
            }
        })
}

function Test-CdpDefaultRunning($Install) {
    @(Get-CdpDesktopProcesses $Install | Where-Object { -not $_.UserDataDir }).Count -gt 0
}

function Test-CdpProfileRunning($Install, [string]$ProfileDir) {
    $dir = $ProfileDir.TrimEnd('\')
    @(Get-CdpDesktopProcesses $Install | Where-Object { $_.UserDataDir -and $_.UserDataDir -ieq $dir }).Count -gt 0
}

# Helper programs that run from inside the default data folder and outlive the app
# (e.g. ChromeNativeHost\chrome-native-host.exe for Claude in Chrome). They lock the folder.
function Stop-CdpDataHelpers($Install) {
    $prefix = (Join-Path $Install.DataRoot 'Claude') + '\'
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Get-CdpAccountId([string]$DataDir) {
    $config = Join-Path $DataDir 'config.json'
    if (-not (Test-Path -LiteralPath $config)) { return $null }
    try {
        $json = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
        if ($json.PSObject.Properties['lastKnownAccountUuid']) { return $json.lastKnownAccountUuid }
    } catch { }
    $null
}

# Undoes a sign-in swap. Exit-style codes: 0 = nothing to do or restored, 2 = default Claude is
# still running (try again after quitting it), 3 = unexpected folder state, left untouched.
function Restore-CdpDefaultProfile($Install, [switch]$NoProcessCheck) {
    $live   = Join-Path $Install.DataRoot 'Claude'
    $backup = Join-Path $Install.DataRoot $script:CdpBackupName
    if (-not (Test-Path -LiteralPath $backup)) { return 0 }
    if (-not $NoProcessCheck -and (Test-CdpDefaultRunning $Install)) { return 2 }

    Stop-CdpDataHelpers $Install
    if (Test-Path -LiteralPath $live) {
        if ((Get-Item -LiteralPath $live -Force).LinkType -ne 'Junction') { return 3 }
        [IO.Directory]::Delete($live)          # removes the junction only, never the profile it points to
    }
    Rename-Item -LiteralPath $backup -NewName 'Claude'
    0
}
