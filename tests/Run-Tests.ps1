<#
.SYNOPSIS
    Test suite for Claude Desktop Profiles. Needs no extra modules (no Pester).
.DESCRIPTION
    Everything runs inside a temporary folder against a fake Claude install (a small compiled
    "claude.exe" that just sleeps), so your real Claude data is never touched. The only real-system
    dependency is the launcher test that checks Claude Desktop is found on this PC; it is skipped
    when Claude is not installed.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
#>
[CmdletBinding()]
param([string]$WorkDir = (Join-Path ([IO.Path]::GetTempPath()) "cdp-tests-$PID"))
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts\Common.ps1')

$script:passed = 0; $script:failed = @()
function Check([string]$Name, [scriptblock]$Test) {
    try {
        $ok = & $Test
        if ($ok -eq $true) { $script:passed++; Write-Host "  PASS  $Name" -ForegroundColor Green }
        else { $script:failed += $Name; Write-Host "  FAIL  $Name  (got: $ok)" -ForegroundColor Red }
    } catch { $script:failed += $Name; Write-Host "  FAIL  $Name  ($($_.Exception.Message))" -ForegroundColor Red }
}
function Section([string]$Title) { Write-Host "`n$Title" -ForegroundColor Cyan }

Add-Type @'
using System; using System.Runtime.InteropServices;
public static class ArgvSplit {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CommandLineToArgvW(string cmd, out int argc);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
    public static string[] Split(string cmd) {
        int argc; IntPtr argv = CommandLineToArgvW("x.exe " + cmd, out argc);
        var r = new string[argc - 1];
        for (int i = 1; i < argc; i++) r[i - 1] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size));
        LocalFree(argv); return r;
    }
}
'@

# --- fixture ------------------------------------------------------------------------------------
Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
$fakeInstallDir = Join-Path $WorkDir 'install'
$dataRoot       = Join-Path $WorkDir 'data'
$profilesRoot   = Join-Path $WorkDir 'profiles'
New-Item -ItemType Directory -Force -Path $fakeInstallDir, $dataRoot, $profilesRoot | Out-Null
$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
$fakeSrc = Join-Path $WorkDir 'fake.cs'
'class F { static void Main(string[] a) { int s = 5; if (a.Length > 0) int.TryParse(a[0], out s); System.Threading.Thread.Sleep(s * 1000); } }' | Set-Content $fakeSrc
& $csc /nologo /target:winexe "/out:$fakeInstallDir\claude.exe" $fakeSrc | Out-Null
$fakeClaude = Join-Path $fakeInstallDir 'claude.exe'

$fakeInstall = [pscustomobject]@{ Kind = 'Test'; Exe = $fakeClaude; InstallDir = $fakeInstallDir; DataRoot = $dataRoot; LaunchTarget = $fakeClaude; LaunchArgs = '8' }
$env:CDP_TEST_INSTALL = $fakeInstall | ConvertTo-Json -Compress
$env:CLAUDE_PROFILES_ROOT = $profilesRoot

$live = Join-Path $dataRoot 'Claude'; $backup = Join-Path $dataRoot 'Claude.default-profile'
function Reset-Data {
    Get-CdpDesktopProcesses $fakeInstall | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    foreach ($p in $live, $backup) {
        if (Test-Path -LiteralPath $p) {
            if ((Get-Item -LiteralPath $p -Force).LinkType) { [IO.Directory]::Delete($p) } else { Remove-Item -LiteralPath $p -Recurse -Force }
        }
    }
    New-Item -ItemType Directory -Path $live | Out-Null
    Set-Content (Join-Path $live 'marker.txt') 'default'
    '{"lastKnownAccountUuid":"11111111-1111-1111-1111-111111111111"}' | Set-Content (Join-Path $live 'config.json')
}
function New-Profile([string]$Name) {
    $d = Join-Path $profilesRoot $Name; New-Item -ItemType Directory -Force -Path $d | Out-Null
    Set-Content (Join-Path $d 'marker.txt') "profile $Name"; $d
}
function Start-Fake([string]$Arguments) { Start-Process $fakeClaude -ArgumentList $Arguments -PassThru }
function Wait-For([scriptblock]$Cond, [int]$Seconds = 20) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) { if (& $Cond) { return $true }; Start-Sleep -Milliseconds 200 }
    $false
}

# Child scripts are expected to fail in some tests; in Windows PowerShell 5.1 their stderr would
# otherwise become a terminating error here. Each Check catches its own failures.
$ErrorActionPreference = 'Continue'
try {
    # ---------------------------------------------------------------------------------------------
    Section 'Profile names'
    foreach ($n in 'Work', 'Client A', 'a_b-1', ('x' * 40)) { Check "accepts '$n'" { Assert-CdpProfileName $n; $true } }
    foreach ($n in '', 'bin', 'BIN', 'default', '..\x', 'a\b', 'x:y', '.hidden', ' lead', ('x' * 41), 'a/b', 'a*b') {
        Check "rejects '$n'" { try { Assert-CdpProfileName $n; 'accepted' } catch { $true } }
    }

    Section 'Command-line parsing'
    Check 'whole-argument quoting'   { (Get-CdpUserDataDir 'claude.exe "--user-data-dir=C:\P\Work Stuff" --x') -eq 'C:\P\Work Stuff' }
    Check 'value quoting'            { (Get-CdpUserDataDir 'claude.exe --user-data-dir="C:\P\Work Stuff" --x') -eq 'C:\P\Work Stuff' }
    Check 'unquoted'                 { (Get-CdpUserDataDir 'claude.exe --user-data-dir=C:\P\Work --type=renderer') -eq 'C:\P\Work' }
    Check 'trailing backslash'       { (Get-CdpUserDataDir 'claude.exe --user-data-dir=C:\P\Work\') -eq 'C:\P\Work' }
    Check 'default profile -> null'  { $null -eq (Get-CdpUserDataDir '"C:\x\claude.exe" claude://login') }

    # ---------------------------------------------------------------------------------------------
    Section 'Process detection'
    $work = New-Profile 'Work'
    $pDefault = Start-Fake '30'
    $pWork = Start-Fake "30 `"--user-data-dir=$work`""
    $pOther = Start-Process (Join-Path $env:WINDIR 'System32\ping.exe') -ArgumentList '-n 30 127.0.0.1' -WindowStyle Hidden -PassThru
    Start-Sleep 1
    Check 'default instance detected'         { Test-CdpDefaultRunning $fakeInstall }
    Check 'profile instance detected'         { Test-CdpProfileRunning $fakeInstall $work }
    Check 'profile match ignores case/slash'  { Test-CdpProfileRunning $fakeInstall ($work.ToUpper() + '\') }
    Check 'other profile not matched'         { -not (Test-CdpProfileRunning $fakeInstall (Join-Path $profilesRoot 'Nope')) }
    Check 'processes outside install ignored' { @(Get-CdpDesktopProcesses $fakeInstall | Where-Object { $_.Id -eq $pOther.Id }).Count -eq 0 }
    Stop-Process -Id $pDefault.Id -Force; Start-Sleep 1
    Check 'profile instance does not count as default' { -not (Test-CdpDefaultRunning $fakeInstall) }
    Stop-Process -Id $pWork.Id, $pOther.Id -Force

    Section 'Helper processes in the data folder'
    Reset-Data
    $helperDir = Join-Path $live 'ChromeNativeHost'; New-Item -ItemType Directory $helperDir | Out-Null
    Copy-Item $fakeClaude (Join-Path $helperDir 'chrome-native-host.exe')
    $helper = Start-Process (Join-Path $helperDir 'chrome-native-host.exe') -ArgumentList '60' -PassThru
    $bystander = Start-Fake '60'
    Start-Sleep 1
    Stop-CdpDataHelpers $fakeInstall; Start-Sleep 1
    Check 'helper inside data folder stopped' { $null -eq (Get-Process -Id $helper.Id -ErrorAction SilentlyContinue) }
    Check 'process outside data folder kept'  { $null -ne (Get-Process -Id $bystander.Id -ErrorAction SilentlyContinue) }
    Stop-Process -Id $bystander.Id -Force

    # ---------------------------------------------------------------------------------------------
    Section 'Restore'
    Reset-Data
    Check 'nothing parked -> 0, untouched' { ((Restore-CdpDefaultProfile $fakeInstall) -eq 0) -and ((Get-Content (Join-Path $live 'marker.txt')) -eq 'default') }

    Reset-Data; Rename-Item $live 'Claude.default-profile'; New-Item -ItemType Junction -Path $live -Target $work | Out-Null
    $before = @(Get-ChildItem -LiteralPath $work -Recurse -Force).Count
    $code = Restore-CdpDefaultProfile $fakeInstall
    Check 'parked -> 0'                       { $code -eq 0 }
    Check 'default data back in place'        { (Get-Content (Join-Path $live 'marker.txt')) -eq 'default' }
    Check 'restored folder is real, not link' { -not (Get-Item -LiteralPath $live -Force).LinkType }
    Check 'backup name gone'                  { -not (Test-Path -LiteralPath $backup) }
    Check 'profile data untouched by unlink'  { ((Get-Content (Join-Path $work 'marker.txt')) -eq 'profile Work') -and (@(Get-ChildItem -LiteralPath $work -Recurse -Force).Count -eq $before) }

    Reset-Data; Rename-Item $live 'Claude.default-profile'; New-Item -ItemType Junction -Path $live -Target $work | Out-Null
    $p = Start-Fake '30'; Start-Sleep 1
    Check 'default running -> 2, nothing changed' { ((Restore-CdpDefaultProfile $fakeInstall) -eq 2) -and (Test-Path $backup) -and ((Get-Item -LiteralPath $live -Force).LinkType -eq 'Junction') }
    Stop-Process -Id $p.Id -Force; Start-Sleep 1
    $p = Start-Fake "30 `"--user-data-dir=$work`""; Start-Sleep 1
    Check 'only a profile running -> still restores' { (Restore-CdpDefaultProfile $fakeInstall) -eq 0 }
    Stop-Process -Id $p.Id -Force

    Reset-Data; New-Item -ItemType Directory $backup | Out-Null; Set-Content (Join-Path $backup 'marker.txt') 'other'
    Check 'two real folders -> 3, nothing changed' { ((Restore-CdpDefaultProfile $fakeInstall) -eq 3) -and ((Get-Content (Join-Path $live 'marker.txt')) -eq 'default') -and ((Get-Content (Join-Path $backup 'marker.txt')) -eq 'other') }

    Reset-Data; Remove-Item $live -Recurse -Force; New-Item -ItemType Directory $backup | Out-Null; Set-Content (Join-Path $backup 'marker.txt') 'default'
    Check 'parked with no link -> renamed back' { ((Restore-CdpDefaultProfile $fakeInstall) -eq 0) -and ((Get-Content (Join-Path $live 'marker.txt')) -eq 'default') }

    # ---------------------------------------------------------------------------------------------
    Section 'install.ps1'
    $inst = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'install.ps1') -Name 'Work' -NoDesktopIcon -NoStartMenu 2>&1
    $bin = Join-Path $profilesRoot 'bin'; $exeWork = Join-Path $bin 'Claude Work.exe'
    Check 'install succeeds'                    { $LASTEXITCODE -eq 0 }
    Check 'launcher built'                      { Test-Path -LiteralPath $exeWork }
    Check 'scripts copied to bin'               { @('Common.ps1', 'SignIn.ps1', 'Restore.ps1', 'Copy-CodeSessions.ps1', 'Uninstall.ps1' | Where-Object { -not (Test-Path (Join-Path $bin $_)) }).Count -eq 0 }
    Check 'profile data kept on reinstall'      { (Get-Content (Join-Path $work 'marker.txt')) -eq 'profile Work' }
    Check 'generated icon has 8 sizes'          { $b = [IO.File]::ReadAllBytes((Join-Path $bin 'icons\Work.ico')); [BitConverter]::ToUInt16($b, 4) -eq 8 }
    Check 'icon embedded in launcher'           { Add-Type -AssemblyName System.Drawing; $null -ne [Drawing.Icon]::ExtractAssociatedIcon($exeWork) }
    Check 'suggests signing in'                 { ($inst -join "`n") -match 'SignIn\.ps1' }

    Add-Type -AssemblyName System.Drawing
    $png = Join-Path $WorkDir 'wide.png'; $bmp = New-Object Drawing.Bitmap 300, 150; $g = [Drawing.Graphics]::FromImage($bmp); $g.Clear([Drawing.Color]::Transparent); $g.FillRectangle([Drawing.Brushes]::OrangeRed, 50, 25, 200, 100); $g.Dispose(); $bmp.Save($png); $bmp.Dispose()
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'install.ps1') -Name 'Client A' -Icon $png -NoDesktopIcon -NoStartMenu | Out-Null
    Check 'name with space + custom PNG icon'   { ($LASTEXITCODE -eq 0) -and (Test-Path (Join-Path $bin 'Claude Client A.exe')) }
    Check 'PNG padded square, corners clear'    {
        # Frame 0 is the 256px PNG; read it directly (System.Drawing.Icon cannot decode PNG frames).
        $b = [IO.File]::ReadAllBytes((Join-Path $bin 'icons\Client A.ico'))
        $len = [BitConverter]::ToUInt32($b, 6 + 8); $off = [BitConverter]::ToUInt32($b, 6 + 12)
        $b2 = [Drawing.Bitmap]::FromStream((New-Object IO.MemoryStream (, $b[$off..($off + $len - 1)])))
        ($b2.Width -eq 256) -and ($b2.Height -eq 256) -and ($b2.GetPixel(0, 0).A -eq 0) -and ($b2.GetPixel(0, 128).A -eq 0) -and ($b2.GetPixel(128, 128).A -eq 255)
    }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'install.ps1') -Name 'bin' -NoDesktopIcon -NoStartMenu 2>&1 | Out-Null
    Check 'reserved name refused'               { $LASTEXITCODE -ne 0 }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'install.ps1') -Name 'X' -Icon 'C:\nope.png' -NoDesktopIcon -NoStartMenu 2>&1 | Out-Null
    Check 'missing icon file refused'           { ($LASTEXITCODE -ne 0) -and -not (Test-Path (Join-Path $profilesRoot 'X')) }

    # ---------------------------------------------------------------------------------------------
    Section 'Launcher'
    function Invoke-Launcher([string]$Exe, [string[]]$Arguments) {
        $o = Join-Path $WorkDir 'out.txt'; $e = Join-Path $WorkDir 'err.txt'
        $argList = @('--dry-run') + $Arguments
        $p = Start-Process -FilePath $Exe -ArgumentList $argList -RedirectStandardOutput $o -RedirectStandardError $e -Wait -PassThru -WindowStyle Hidden
        [pscustomobject]@{ Code = $p.ExitCode; Out = @(Get-Content $o); Err = (Get-Content $e -Raw) }
    }
    $r = Invoke-Launcher $exeWork @()
    $claudeInstalled = $r.Code -eq 0
    if ($claudeInstalled) {
        Check 'resolves installed Claude Desktop'  { Test-Path -LiteralPath $r.Out[0] }
        Check 'profile taken from file name'       { $a = [ArgvSplit]::Split($r.Out[1]); ($a.Count -eq 1) -and ($a[0] -eq "--user-data-dir=$work") }
        $r = Invoke-Launcher (Join-Path $bin 'Claude Client A.exe') @()
        Check 'profile name with a space is quoted' { $a = [ArgvSplit]::Split($r.Out[1]); $a[0] -eq ('--user-data-dir=' + (Join-Path $profilesRoot 'Client A')) }
        $r = Invoke-Launcher $exeWork @('"--profile=Client A"')
        Check '--profile overrides file name'      { ([ArgvSplit]::Split($r.Out[1]))[0] -like '*\Client A' }
        $tricky = 'claude://login/callback?code=a b&state="q"\'
        $r = Invoke-Launcher $exeWork @(('"' + $tricky.Replace('\', '\\').Replace('"', '\"') + '"'))
        Check 'extra arguments survive quoting'    { $a = [ArgvSplit]::Split($r.Out[1]); ($a.Count -eq 2) -and ($a[1] -eq $tricky) }
    } else {
        Write-Host "  SKIP  launcher resolution tests (Claude Desktop not installed: $($r.Err.Trim()))" -ForegroundColor Yellow
    }
    $r = Invoke-Launcher $exeWork @('--profile=Missing')
    Check 'missing profile -> error'               { ($r.Code -eq 1) -and ($r.Err -match 'does not exist') }
    $r = Invoke-Launcher $exeWork @('--profile=..\evil')
    Check 'invalid --profile -> error'             { ($r.Code -eq 1) -and ($r.Err -match 'Could not tell') }
    $plain = Join-Path $bin 'Launcher.exe'; Copy-Item $exeWork $plain
    $r = Invoke-Launcher $plain @()
    Check 'unrecognised file name -> error'        { ($r.Code -eq 1) -and ($r.Err -match 'Could not tell') }

    # ---------------------------------------------------------------------------------------------
    Section 'SignIn.ps1 (full swap against the fake install)'
    function Start-SignIn([string]$Name) {
        $log = Join-Path $WorkDir "signin-$([guid]::NewGuid().ToString('n')).txt"
        $p = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$bin\SignIn.ps1`"", '-Name', "`"$Name`"", '-TimeoutMinutes', '1' -RedirectStandardOutput $log -WindowStyle Hidden -PassThru
        [pscustomobject]@{ Process = $p; Log = $log }
    }
    Reset-Data
    New-Item -ItemType Directory -Force $helperDir | Out-Null
    Copy-Item $fakeClaude (Join-Path $helperDir 'chrome-native-host.exe')
    $helper = Start-Process (Join-Path $helperDir 'chrome-native-host.exe') -ArgumentList '60' -PassThru
    $blocking = Start-Fake '4'           # default Claude still open when the script starts
    $s = Start-SignIn 'Work'
    Check 'waits while default Claude is open'  { Start-Sleep 2; (Test-Path -LiteralPath $live) -and -not (Get-Item -LiteralPath $live -Force).LinkType }
    Check 'parks default + links profile'       { Wait-For { (Test-Path $backup) -and ((Get-Item -LiteralPath $live -Force).LinkType -eq 'Junction') } }
    Check 'helper holding the folder stopped'   { $null -eq (Get-Process -Id $helper.Id -ErrorAction SilentlyContinue) }
    Check 'opens Claude on the profile'         { Wait-For { Test-CdpDefaultRunning $fakeInstall } }
    '{"lastKnownAccountUuid":"22222222-2222-2222-2222-222222222222"}' | Set-Content (Join-Path $live 'config.json')   # the "sign-in"
    Check 'script finishes after Claude quits'  { $s.Process.WaitForExit(30000) }
    Check 'default profile restored'            { ((Get-Content (Join-Path $live 'marker.txt')) -eq 'default') -and -not (Test-Path $backup) }
    Check 'sign-in landed in the profile'       { (Get-CdpAccountId $work) -eq '22222222-2222-2222-2222-222222222222' }
    Check 'default account unchanged'           { (Get-CdpAccountId $live) -eq '11111111-1111-1111-1111-111111111111' }
    Check 'reports success'                     { (Get-Content $s.Log -Raw) -match 'Done\.' }

    Reset-Data
    $s = Start-SignIn 'Work'
    Wait-For { Test-CdpDefaultRunning $fakeInstall } | Out-Null
    '{"lastKnownAccountUuid":"11111111-1111-1111-1111-111111111111"}' | Set-Content (Join-Path $live 'config.json')
    $s.Process.WaitForExit(30000) | Out-Null
    Check 'warns when profile got the same account' { (Get-Content $s.Log -Raw) -match 'SAME account' }

    Reset-Data
    $fakeInstall.LaunchArgs = '60'; $env:CDP_TEST_INSTALL = $fakeInstall | ConvertTo-Json -Compress
    $s = Start-SignIn 'Work'
    Wait-For { Test-CdpDefaultRunning $fakeInstall } | Out-Null
    Stop-Process -Id $s.Process.Id -Force           # window closed mid-sign-in
    Check 'interrupted: default stays parked'   { Test-Path $backup }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'Restore.ps1') | Out-Null
    Check 'Restore.ps1 refuses while Claude open' { $LASTEXITCODE -eq 2 }
    Get-CdpDesktopProcesses $fakeInstall | ForEach-Object { Stop-Process -Id $_.Id -Force }; Start-Sleep 1
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'Restore.ps1') | Out-Null
    Check 'Restore.ps1 recovers after quit'     { ($LASTEXITCODE -eq 0) -and ((Get-Content (Join-Path $live 'marker.txt')) -eq 'default') -and ((Get-Content (Join-Path $work 'marker.txt')) -eq 'profile Work') }
    $fakeInstall.LaunchArgs = '8'; $env:CDP_TEST_INSTALL = $fakeInstall | ConvertTo-Json -Compress

    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'SignIn.ps1') -Name 'Ghost' 2>&1 | Out-Null
    Check 'unknown profile refused'             { $LASTEXITCODE -ne 0 }

    # ---------------------------------------------------------------------------------------------
    Section 'Copy-CodeSessions.ps1'
    Reset-Data
    $acct = '22222222-2222-2222-2222-222222222222'; $org = '33333333-3333-3333-3333-333333333333'
    "{`"lastKnownAccountUuid`":`"$acct`"}" | Set-Content (Join-Path $work 'config.json')
    $src = Join-Path $live "claude-code-sessions\$acct\$org"; New-Item -ItemType Directory -Force $src | Out-Null
    1..3 | ForEach-Object { "{`"title`":`"chat $_`",`"cwd`":`"C:\\proj`"}" | Set-Content (Join-Path $src "local_$_.json") }
    $other = Join-Path $live "claude-code-sessions\44444444-4444-4444-4444-444444444444\$org"; New-Item -ItemType Directory -Force $other | Out-Null
    '{"title":"x","cwd":"C:\\other"}' | Set-Content (Join-Path $other 'local_x.json')
    $dst = Join-Path $work "claude-code-sessions\$acct\$org"; New-Item -ItemType Directory -Force $dst | Out-Null
    'KEEP' | Set-Content (Join-Path $dst 'local_1.json')
    $cs = Join-Path $bin 'Copy-CodeSessions.ps1'
    $list = & powershell -NoProfile -ExecutionPolicy Bypass -File $cs -Name Work -List -SourceDataDir $live 2>&1
    Check '-List shows accounts and folders'     { ($list -join "`n") -match [regex]::Escape($acct) -and ($list -join "`n") -match 'C:\\proj' }
    & powershell -NoProfile -ExecutionPolicy Bypass -File $cs -Name Work -SourceDataDir $live -WhatIf | Out-Null
    Check '-WhatIf copies nothing'               { @(Get-ChildItem $dst).Count -eq 1 }
    & powershell -NoProfile -ExecutionPolicy Bypass -File $cs -Name Work -SourceDataDir $live | Out-Null
    Check "copies the profile's account"        { @(Get-ChildItem $dst -Filter 'local_*.json').Count -eq 3 }
    Check 'never overwrites existing files'      { (Get-Content (Join-Path $dst 'local_1.json')) -eq 'KEEP' }
    Check 'other accounts not copied'            { -not (Test-Path (Join-Path $work 'claude-code-sessions\44444444-4444-4444-4444-444444444444')) }
    Check 'source left intact'                   { @(Get-ChildItem $src).Count -eq 3 }
    & powershell -NoProfile -ExecutionPolicy Bypass -File $cs -Name Work -SourceDataDir $live -AccountId 'not-an-id' 2>&1 | Out-Null
    Check 'bad account id refused'               { $LASTEXITCODE -ne 0 }
    & powershell -NoProfile -ExecutionPolicy Bypass -File $cs -Name 'Client A' -SourceDataDir $live 2>&1 | Out-Null
    Check 'unsigned profile needs -AccountId'    { $LASTEXITCODE -ne 0 }

    # ---------------------------------------------------------------------------------------------
    Section 'Uninstall.ps1'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'Uninstall.ps1') -Name 'Client A' | Out-Null
    Check 'removes launcher + icon'              { -not (Test-Path (Join-Path $bin 'Claude Client A.exe')) -and -not (Test-Path (Join-Path $bin 'icons\Client A.ico')) }
    Check 'keeps data by default'                { Test-Path (Join-Path $profilesRoot 'Client A') }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'Uninstall.ps1') -Name 'Client A' -DeleteData -Force | Out-Null
    Check '-DeleteData -Force removes data'      { -not (Test-Path (Join-Path $profilesRoot 'Client A')) }
    Check 'other profiles untouched'             { (Test-Path $exeWork) -and ((Get-Content (Join-Path $work 'marker.txt')) -eq 'profile Work') }
    $p = Start-Fake "30 `"--user-data-dir=$work`""; Start-Sleep 1
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'Uninstall.ps1') -Name 'Work' 2>&1 | Out-Null
    Check 'refuses while the profile is open'    { ($LASTEXITCODE -ne 0) -and (Test-Path $exeWork) }
    Stop-Process -Id $p.Id -Force
}
finally {
    Get-CdpDesktopProcesses $fakeInstall | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($WorkDir, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:\CDP_TEST_INSTALL, Env:\CLAUDE_PROFILES_ROOT -ErrorAction SilentlyContinue
    Start-Sleep 1
    if (Test-Path -LiteralPath $live) { if ((Get-Item -LiteralPath $live -Force).LinkType) { [IO.Directory]::Delete($live) } }
    Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failed.Count) {
    Write-Host "$($script:passed) passed, $($script:failed.Count) failed:" -ForegroundColor Red
    $script:failed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "All $($script:passed) tests passed." -ForegroundColor Green
