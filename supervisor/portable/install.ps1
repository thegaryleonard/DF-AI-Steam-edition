# df-ai stream: install this package on another Windows PC.
# Run INSTALL.bat (it calls this). Safe to run again: everything it replaces is
# backed up first, and saves that already exist are never overwritten.
#
#   -DfDir <path>       the Dwarf Fortress folder (found through Steam if left out)
#   -AppDataDir <path>  DF's user folder (default %APPDATA%\Bay 12 Games\Dwarf Fortress)
#   -StreamDir <path>   where the stream helpers go (default %USERPROFILE%\dfai-stream\df-ai\supervisor)
#   -NoPython           don't look for / install Python
#   -NoShortcuts        don't put Start/Stop shortcuts on the desktop
#   -Yes                don't ask questions (take the defaults)
param(
    [string]$DfDir = '',
    [string]$AppDataDir = '',
    [string]$StreamDir = '',
    [switch]$NoPython,
    [switch]$NoShortcuts,
    [switch]$Yes,
    [switch]$TestOnly   # (packaging test: skips the 'DF is running' check)
)
$ErrorActionPreference = 'Stop'
$Pkg = $PSScriptRoot
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
function Say($t) { Write-Host $t }
function Step($t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Warn($t) { Write-Host "   ! $t" -ForegroundColor Yellow }
function Ask($q) {
    if ($Yes) { return $true }
    $a = Read-Host "$q [Y/n]"
    return ($a -eq '' -or $a -match '^[Yy]')
}
function Copy-Merge($from, $to, $backupRoot, $label) {
    # copies every file in $from into $to, keeping a copy of each file it replaces
    $n = 0; $b = 0
    Get-ChildItem -LiteralPath $from -Recurse -File -Force | ForEach-Object {
        $rel = $_.FullName.Substring($from.Length).TrimStart('\')
        $dst = Join-Path $to $rel
        if (Test-Path -LiteralPath $dst) {
            $old = Get-Item -LiteralPath $dst
            if ($old.Length -ne $_.Length -or $old.LastWriteTimeUtc -ne $_.LastWriteTimeUtc) {
                $bk = Join-Path $backupRoot $rel
                New-Item -ItemType Directory -Force -Path (Split-Path $bk) | Out-Null
                Copy-Item -LiteralPath $dst -Destination $bk -Force
                $b++
            }
        }
        New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $dst -Force
        $n++
    }
    Say "   $label`: $n files copied ($b replaced files backed up)"
}

Write-Host ''
Write-Host 'df-ai stream installer' -ForegroundColor Green
Write-Host "package: $Pkg"

# ---------------------------------------------------------------- the game
Step 'Finding Dwarf Fortress'
if (-not $DfDir) {
    $cands = @()
    $steam = $null
    foreach ($k in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        try { $v = Get-ItemProperty -Path $k -ErrorAction Stop; if ($v.SteamPath) { $steam = $v.SteamPath } elseif ($v.InstallPath) { $steam = $v.InstallPath } } catch {}
        if ($steam) { break }
    }
    $libs = @()
    if ($steam) {
        $libs += $steam
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' | ForEach-Object { $libs += $_.Matches[0].Groups[1].Value -replace '\\\\', '\' }
        }
    }
    $libs += 'C:\Program Files (x86)\Steam', 'C:\Program Files\Steam', 'D:\SteamLibrary', 'E:\SteamLibrary'
    foreach ($l in $libs | Select-Object -Unique) {
        $c = Join-Path $l 'steamapps\common\Dwarf Fortress'
        if (Test-Path (Join-Path $c 'Dwarf Fortress.exe')) { $cands += $c }
    }
    if ($cands.Count -gt 0) { $DfDir = $cands[0] }
}
while (-not $DfDir -or -not (Test-Path (Join-Path $DfDir 'Dwarf Fortress.exe'))) {
    if ($Yes) { throw 'Dwarf Fortress not found; run again with -DfDir "<folder with Dwarf Fortress.exe>"' }
    Warn 'Could not find Dwarf Fortress. Install it from Steam first (and DFHack from Steam too).'
    $DfDir = (Read-Host 'Paste the folder that has "Dwarf Fortress.exe" in it (or Ctrl+C to stop)').Trim('"', ' ')
}
Say "   game: $DfDir"
if (-not $TestOnly -and (Get-Process -Name 'Dwarf Fortress' -ErrorAction SilentlyContinue)) {
    throw 'Dwarf Fortress is running. Save and quit it, then run the installer again.'
}
$want = (Get-Content (Join-Path $Pkg 'VERSION.txt') -ErrorAction SilentlyContinue) -join ' '
Say "   this package was built for: $want"
$exe = Get-Item (Join-Path $DfDir 'Dwarf Fortress.exe')
$pkgExeSize = 0
$m = [regex]::Match($want, 'exe_size=(\d+)')
if ($m.Success) { $pkgExeSize = [int64]$m.Groups[1].Value }
if ($pkgExeSize -and $exe.Length -ne $pkgExeSize) {
    Warn "This Dwarf Fortress.exe is a different build ($($exe.Length) bytes, the package expects $pkgExeSize)."
    Warn 'df-ai and its helpers only work on DF 53.16 (Steam). If Steam updated DF, they will not load.'
    if (-not (Ask '   Install anyway?')) { exit 1 }
}

# ---------------------------------------------------------------- DFHack + df-ai + scripts
Step 'Installing DFHack (this exact build), df-ai, its scripts and blueprints'
$gameBackup = Join-Path $DfDir "dfai-backup-$Stamp"
Copy-Merge (Join-Path $Pkg 'game') $DfDir $gameBackup 'game folder'
if (Test-Path $gameBackup) { Say "   anything replaced is in $gameBackup" }

# ---------------------------------------------------------------- saves, prefs, mods
Step 'Copying the fort, the world, settings and mods'
if (-not $AppDataDir) { $AppDataDir = Join-Path $env:APPDATA 'Bay 12 Games\Dwarf Fortress' }
New-Item -ItemType Directory -Force -Path (Join-Path $AppDataDir 'save') | Out-Null
$userBackup = Join-Path $AppDataDir "dfai-backup-$Stamp"
foreach ($sub in 'prefs', 'mods') {
    $src = Join-Path $Pkg "appdata\$sub"
    if (Test-Path $src) { Copy-Merge $src (Join-Path $AppDataDir $sub) (Join-Path $userBackup $sub) $sub }
}
$saveSrc = Join-Path $Pkg 'appdata\save'
if (Test-Path $saveSrc) {
    Get-ChildItem -LiteralPath $saveSrc -Directory | ForEach-Object {
        $dst = Join-Path $AppDataDir "save\$($_.Name)"
        if (Test-Path $dst) {
            Warn "save '$($_.Name)' is already there - left as it is (delete or rename it and run again to replace it)"
        } else {
            Copy-Item -LiteralPath $_.FullName -Destination $dst -Recurse
            # newest = the one the game manager loads
            # (the manager picks the save whose files are newest)
            if ($_.Name -notmatch '^region') { Get-ChildItem -LiteralPath $dst -Filter 'world.*' -File | ForEach-Object { $_.LastWriteTime = Get-Date } }
            Say "   save '$($_.Name)' copied"
        }
    }
}

# ---------------------------------------------------------------- the stream helpers
Step 'Installing the stream helpers (broadsheet, stream page, overseer desk, game manager)'
if (-not $StreamDir) { $StreamDir = Join-Path $env:USERPROFILE 'dfai-stream\df-ai\supervisor' }
if (Test-Path (Join-Path $StreamDir 'dfai_supervisor.py')) {
    $sb = "$StreamDir-backup-$Stamp"
    Say "   an older copy is there; moving it to $sb"
    if (-not $TestOnly) { Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'dfai_supervisor\.py|overlay\.py|overseer\.py|gamefeed\.py|lan_proxy\.py|twitch_chat_log\.py' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
    Start-Sleep -Seconds 1
    Move-Item -LiteralPath $StreamDir -Destination $sb
}
New-Item -ItemType Directory -Force -Path $StreamDir | Out-Null
Copy-Item -Path (Join-Path $Pkg 'stream\*') -Destination $StreamDir -Recurse -Force
New-Item -ItemType Directory -Force -Path (Join-Path $StreamDir 'logs') | Out-Null
# supervisor.json: this PC's game folder (other settings kept)
$cfgPath = Join-Path $StreamDir 'supervisor.json'
$cfg = @{}
if (Test-Path $cfgPath) { (Get-Content $cfgPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $cfg[$_.Name] = $_.Value } }
$cfg['df_dir'] = $DfDir
$cfg['save_dir'] = (Join-Path $AppDataDir 'save')
$obs = @("$env:ProgramFiles\obs-studio\bin\64bit\obs64.exe", "${env:ProgramFiles(x86)}\obs-studio\bin\64bit\obs64.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($obs) { $cfg['obs_exe'] = $obs } else { $cfg['obs_keeper'] = $false }
[IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))   # no BOM
Say "   installed in $StreamDir"

# ---------------------------------------------------------------- python
if (-not $NoPython) {
    Step 'Python'
    function Find-Python {
        $c = @()
        try { $c += (& py -3 -c 'import sys; print(sys.executable)' 2>$null) } catch {}
        foreach ($g in "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", "$env:LOCALAPPDATA\Python\pythoncore-3*\python.exe", "$env:ProgramFiles\Python3*\python.exe") {
            $c += (Get-ChildItem $g -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | ForEach-Object FullName)
        }
        $c += (Get-Command python -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch 'WindowsApps' } | ForEach-Object Source)
        foreach ($p in $c) {
            if ($p -and (Test-Path $p)) {
                $v = & $p -c 'import sys; print(sys.version_info[0]*100+sys.version_info[1])' 2>$null
                if ([int]$v -ge 310) { return $p }
            }
        }
        return $null
    }
    $py = Find-Python
    if (-not $py) {
        Say '   Python 3.10+ not found.'
        if (Ask '   Install Python 3.12 with winget now?') {
            winget install -e --id Python.Python.3.12 --scope user --accept-package-agreements --accept-source-agreements
            $py = Find-Python
        }
    }
    if ($py) {
        Say "   using $py"
        [IO.File]::WriteAllText((Join-Path $StreamDir 'python.txt'), $py, (New-Object Text.UTF8Encoding $false))
        & $py -m pip install --quiet --disable-pip-version-check pillow
        if ($LASTEXITCODE -ne 0) { Warn 'pip could not install pillow (the stream page needs it); try: python -m pip install pillow' }
        else { Say '   pillow installed' }
    } else {
        Warn 'No Python: install Python 3.12 from python.org, then run this installer again.'
    }
}

# ---------------------------------------------------------------- OBS scenes
$scenes = Join-Path $Pkg 'obs\scenes'
if ((Test-Path $scenes) -and -not $TestOnly) {
    Step 'OBS scene collection'
    $dst = Join-Path $env:APPDATA 'obs-studio\basic\scenes'
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Get-ChildItem $scenes -Filter *.json | ForEach-Object {
        $name = 'dfai-stream.json'
        $t = Join-Path $dst $name
        if (Test-Path $t) { Say "   $name already in OBS - left as it is" }
        else { Copy-Item $_.FullName $t; Say "   added '$name' (OBS: Scene Collection > dfai-stream)" }
    }
    if (-not $obs) { Warn 'OBS is not installed; the stream helpers run without it (install OBS and run this again to stream)' }
}

# ---------------------------------------------------------------- shortcuts
if (-not $NoShortcuts) {
    Step 'Desktop shortcuts'
    $ws = New-Object -ComObject WScript.Shell
    $desk = [Environment]::GetFolderPath('Desktop')
    foreach ($s in @(@('DF-AI stream - start', 'start-dfai-stream.bat'), @('DF-AI stream - stop', 'stop-dfai-stream.bat'))) {
        $lnk = $ws.CreateShortcut((Join-Path $desk "$($s[0]).lnk"))
        $lnk.TargetPath = Join-Path $StreamDir $s[1]
        $lnk.WorkingDirectory = $StreamDir
        $lnk.Save()
        Say "   $($s[0])"
    }
}

Step 'Done'
Say "   Start everything: the 'DF-AI stream - start' shortcut (or $StreamDir\start-dfai-stream.bat)."
Say '   It opens Dwarf Fortress through Steam, loads the newest save and turns df-ai on.'
Say '   Broadsheet http://localhost:8765/   stream page http://localhost:8766/   overseer desk http://localhost:8767/'
