# df-ai installer: copies df-ai into your Dwarf Fortress folder.
# Run INSTALL.bat (it calls this). Safe to run again. Every file it replaces is
# backed up first, and your saves are never touched.
#   -DfDir "<folder with Dwarf Fortress.exe>"   if it can't find the game itself
param([string]$DfDir = '', [switch]$Yes, [switch]$TestOnly)
$ErrorActionPreference = 'Stop'
$Pkg = $PSScriptRoot
function Say($t) { Write-Host $t }
function Step($t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Warn($t) { Write-Host "   ! $t" -ForegroundColor Yellow }
function Ask($q) { if ($Yes) { return $true }; $a = Read-Host "$q [Y/n]"; return ($a -eq '' -or $a -match '^[Yy]') }

Write-Host ''
Write-Host 'df-ai installer' -ForegroundColor Green
Say ((Get-Content (Join-Path $Pkg 'VERSION.txt') -ErrorAction SilentlyContinue | Select-Object -First 1))

Step 'Finding Dwarf Fortress'
if (-not $DfDir) {
    $libs = @()
    foreach ($k in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        try { $v = Get-ItemProperty -Path $k -ErrorAction Stop; foreach ($p in $v.SteamPath, $v.InstallPath) { if ($p) { $libs += $p } } } catch {}
    }
    foreach ($s in @($libs)) {
        $vdf = Join-Path $s 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) { Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' | ForEach-Object { $libs += $_.Matches[0].Groups[1].Value -replace '\\\\', '\' } }
    }
    $libs += 'C:\Program Files (x86)\Steam', 'C:\Program Files\Steam', 'D:\SteamLibrary', 'E:\SteamLibrary'
    foreach ($l in $libs | Select-Object -Unique) {
        $c = Join-Path $l 'steamapps\common\Dwarf Fortress'
        if (Test-Path (Join-Path $c 'Dwarf Fortress.exe')) { $DfDir = $c; break }
    }
}
while (-not $DfDir -or -not (Test-Path (Join-Path $DfDir 'Dwarf Fortress.exe'))) {
    Warn 'Could not find Dwarf Fortress.'
    Say  '   In Steam: right-click Dwarf Fortress > Manage > Browse local files. Copy that folder''s address.'
    $DfDir = (Read-Host '   Paste it here (or close this window to stop)').Trim('"', ' ')
}
Say "   found: $DfDir"

if (-not $TestOnly -and (Get-Process -Name 'Dwarf Fortress' -ErrorAction SilentlyContinue)) {
    Warn 'Dwarf Fortress is running. Save, quit the game, then run INSTALL.bat again.'
    exit 1
}

Step 'Checking DFHack'
if (-not (Test-Path (Join-Path $DfDir 'hack\dfhack-run.exe'))) {
    Warn 'DFHack is not installed in this Dwarf Fortress folder.'
    Say  '   1. In Steam, search the Store for "DFHack" and install it (it is free).'
    Say  '   2. Start Dwarf Fortress once from Steam so DFHack sets itself up, then quit.'
    Say  '   3. Run INSTALL.bat again.'
    exit 1
}
Say '   DFHack is installed.'
$want = (Get-Content (Join-Path $Pkg 'VERSION.txt') -ErrorAction SilentlyContinue) -join ' '
$m = [regex]::Match($want, 'exe_size=(\d+)')
if ($m.Success -and [int64]$m.Groups[1].Value -gt 0) {
    $have = (Get-Item (Join-Path $DfDir 'Dwarf Fortress.exe')).Length
    if ($have -ne [int64]$m.Groups[1].Value) {
        Warn 'Your Dwarf Fortress is a different version from the one this df-ai was built for (53.16).'
        Warn 'If it is newer, df-ai will not load until a matching df-ai download comes out.'
        if (-not (Ask '   Install anyway?')) { exit 1 }
    }
}

Step 'Copying df-ai into the game folder'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $DfDir "df-ai-backup-$stamp"
$src = Join-Path $Pkg 'game'
$n = 0; $b = 0
Get-ChildItem -LiteralPath $src -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($src.Length).TrimStart('\')
    $dst = Join-Path $DfDir $rel
    if (Test-Path -LiteralPath $dst) {
        if ((Get-FileHash -LiteralPath $dst).Hash -ne (Get-FileHash -LiteralPath $_.FullName).Hash) {
            $bk = Join-Path $backup $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $bk) | Out-Null
            Copy-Item -LiteralPath $dst -Destination $bk -Force
            $b++
        }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
    Copy-Item -LiteralPath $_.FullName -Destination $dst -Force
    Unblock-File -LiteralPath $dst -ErrorAction SilentlyContinue
    $n++
}
Say "   $n files copied."
if ($b) { Say "   $b older files were replaced; the old copies are in $backup" }

Write-Host ''
Write-Host 'Done!' -ForegroundColor Green
Say 'Next:'
Say '  1. Start Dwarf Fortress from Steam (DFHack starts with it).'
Say '  2. Make a world and embark as usual (or load a fresh embark).'
Say '  3. When the fort appears, press ` (the key under Esc) to open the DFHack console'
Say '     and type:   enable df-ai'
Say 'The dwarves are on their own from there. See README-FIRST.txt for more.'
