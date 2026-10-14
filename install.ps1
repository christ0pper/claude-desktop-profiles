<#
.SYNOPSIS
    Creates (or updates) a separate Claude Desktop profile with its own launcher.
.DESCRIPTION
    Creates %USERPROFILE%\ClaudeProfiles\<Name>, builds "Claude <Name>.exe" with the C# compiler that
    ships with Windows, and adds it to the Desktop and Start Menu. Re-running it updates the launcher
    and icon; the profile's data is never touched.
.PARAMETER Name
    Profile name, e.g. Work. Letters, digits, spaces, '-' and '_' (max 40).
.PARAMETER Icon
    Optional .png or .ico for the launcher. A .png should have a transparent background and is
    padded to a square. Without it, a letter badge is generated.
.PARAMETER NoDesktopIcon
    Do not put the launcher on the Desktop.
.PARAMETER NoStartMenu
    Do not add a Start Menu entry.
.EXAMPLE
    .\install.ps1 -Name Work
.EXAMPLE
    .\install.ps1 -Name "Client A" -Icon .\client-a.png
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$Icon,
    [switch]$NoDesktopIcon,
    [switch]$NoStartMenu
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'scripts\Common.ps1')
Add-Type -AssemblyName System.Drawing

function New-CdpBadge([string]$Text) {
    $palette = '#D97757', '#4F7CAC', '#5A9E6F', '#8E6BBF', '#C9A227', '#C2557A', '#3D9DA3', '#7A7A7A'
    $hash = 0; foreach ($ch in $Text.ToCharArray()) { $hash = ($hash * 31 + [int]$ch) % 1000003 }
    $color = [Drawing.ColorTranslator]::FromHtml($palette[$hash % $palette.Count])
    $bmp = New-Object Drawing.Bitmap 256, 256
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $r = 56; $s = 240; $o = 8
    $path.AddArc($o, $o, $r, $r, 180, 90); $path.AddArc($o + $s - $r, $o, $r, $r, 270, 90)
    $path.AddArc($o + $s - $r, $o + $s - $r, $r, $r, 0, 90); $path.AddArc($o, $o + $s - $r, $r, $r, 90, 90); $path.CloseFigure()
    $g.FillPath((New-Object Drawing.SolidBrush $color), $path)
    $font = New-Object Drawing.Font 'Segoe UI', 120, ([Drawing.FontStyle]::Bold), ([Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $g.DrawString($Text.Substring(0, 1).ToUpperInvariant(), $font, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF 0, 6, 256, 256), $fmt)
    $g.Dispose()
    $bmp
}

function ConvertTo-CdpSquare([Drawing.Image]$Image) {
    $side = [Math]::Max($Image.Width, $Image.Height)
    $bmp = New-Object Drawing.Bitmap $side, $side
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.Clear([Drawing.Color]::Transparent)
    $g.DrawImage($Image, [int](($side - $Image.Width) / 2), [int](($side - $Image.Height) / 2), $Image.Width, $Image.Height)
    $g.Dispose()
    $bmp
}

# Writes a multi-size .ico with PNG-compressed frames (supported since Windows Vista).
function Save-CdpIco([Drawing.Image]$Image, [string]$Path) {
    $sizes = 256, 64, 48, 40, 32, 24, 20, 16
    $frames = foreach ($size in $sizes) {
        $bmp = New-Object Drawing.Bitmap $size, $size
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'
        $g.Clear([Drawing.Color]::Transparent); $g.DrawImage($Image, 0, 0, $size, $size); $g.Dispose()
        $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        , $ms.ToArray()
    }
    $fs = [IO.File]::Create($Path); $w = New-Object IO.BinaryWriter $fs
    try {
        $w.Write([UInt16]0); $w.Write([UInt16]1); $w.Write([UInt16]$sizes.Count)
        $offset = 6 + 16 * $sizes.Count
        for ($i = 0; $i -lt $sizes.Count; $i++) {
            $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
            $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
            $w.Write([UInt16]1); $w.Write([UInt16]32); $w.Write([UInt32]$frames[$i].Length); $w.Write([UInt32]$offset)
            $offset += $frames[$i].Length
        }
        foreach ($frame in $frames) { $w.Write($frame) }
    } finally { $w.Close() }
}

# --- checks -------------------------------------------------------------------------------------
Assert-CdpProfileName $Name
$install = Get-CdpInstall
$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw "C# compiler not found at $csc (.NET Framework 4.x is required)." }
if ($Icon -and -not (Test-Path -LiteralPath $Icon)) { throw "Icon file not found: $Icon" }

$root       = Get-CdpRoot
$bin        = Join-Path $root 'bin'
$profileDir = Join-Path $root $Name
$exeName    = "Claude $Name.exe"
$exe        = Join-Path $bin $exeName
$ico        = Join-Path $bin "icons\$Name.ico"
if (Test-CdpProfileRunning $install $profileDir) { Write-Warning "'Claude $Name' is running; the new launcher takes effect next time you open it." }

# --- files --------------------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $profileDir, (Join-Path $bin 'icons') | Out-Null
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'scripts') -Filter '*.ps1') {
    Copy-Item -LiteralPath $file.FullName -Destination $bin -Force
}
Get-ChildItem -LiteralPath $bin -Filter '*.ps1' | Unblock-File

if ($Icon -and [IO.Path]::GetExtension($Icon) -ieq '.ico') {
    Copy-Item -LiteralPath $Icon -Destination $ico -Force
} else {
    $source = if ($Icon) { [Drawing.Image]::FromFile((Resolve-Path -LiteralPath $Icon).Path) } else { New-CdpBadge $Name }
    $square = ConvertTo-CdpSquare $source
    try { Save-CdpIco $square $ico } finally { $square.Dispose(); $source.Dispose() }
}

$out = & $csc /nologo /target:winexe /optimize+ "/win32icon:$ico" /r:System.Windows.Forms.dll "/out:$exe" (Join-Path $PSScriptRoot 'src\Launcher.cs') 2>&1
if ($LASTEXITCODE -ne 0) { throw "Compiling the launcher failed:`n$($out -join "`n")" }

# A real .exe on the Desktop (not a shortcut) so Windows shows no shortcut arrow on it.
if (-not $NoDesktopIcon) { Copy-Item -LiteralPath $exe -Destination (Join-Path ([Environment]::GetFolderPath('Desktop')) $exeName) -Force }
if (-not $NoStartMenu) {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) "Claude $Name.lnk"))
    $lnk.TargetPath = $exe; $lnk.WorkingDirectory = $bin; $lnk.IconLocation = "$exe,0"
    $lnk.Description = "Claude Desktop - $Name profile"
    $lnk.Save()
}

# --- next steps ---------------------------------------------------------------------------------
Write-Host ''
Write-Host "Profile '$Name' is ready ($($install.Kind) install of Claude Desktop)." -ForegroundColor Green
Write-Host "  Data:     $profileDir"
Write-Host "  Launcher: $exe"
if (-not (Get-CdpAccountId $profileDir)) {
    Write-Host ''
    Write-Host 'Next, sign it in (Claude Desktop cannot finish a sign-in in a profile by itself):' -ForegroundColor Cyan
    Write-Host "  & `"$bin\SignIn.ps1`" -Name `"$Name`""
}
