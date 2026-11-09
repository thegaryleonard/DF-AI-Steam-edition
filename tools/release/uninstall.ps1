# df-ai uninstaller: removes exactly the files INSTALL.bat put in the game
# folder (listed in FILES.txt). Saves, worlds and your own files are kept.
[CmdletBinding()]
param([string]$DfDir = '', [switch]$TestOnly)
$ErrorActionPreference = 'Stop'
$Pkg = $PSScriptRoot
if (-not $DfDir) {
    foreach ($l in 'C:\Program Files (x86)\Steam', 'C:\Program Files\Steam', 'D:\SteamLibrary', 'E:\SteamLibrary') {
        $c = Join-Path $l 'steamapps\common\Dwarf Fortress'
        if (Test-Path (Join-Path $c 'Dwarf Fortress.exe')) { $DfDir = $c; break }
    }
}
while (-not $DfDir -or -not (Test-Path (Join-Path $DfDir 'Dwarf Fortress.exe'))) {
    $DfDir = (Read-Host 'Paste the Dwarf Fortress folder (Steam: right-click the game > Manage > Browse local files)').Trim('"', ' ')
}
if (-not $TestOnly -and (Get-Process -Name 'Dwarf Fortress' -ErrorAction SilentlyContinue)) { Write-Host 'Quit Dwarf Fortress first, then run this again.' -ForegroundColor Yellow; exit 1 }
$n = 0
foreach ($rel in Get-Content (Join-Path $Pkg 'FILES.txt')) {
    $p = Join-Path $DfDir ($rel -replace '/', '\')
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; $n++ }
}
Write-Host "Removed $n df-ai files from $DfDir." -ForegroundColor Green
Write-Host 'Kept: your saves, df-ai.json settings, logs, and the df-ai-backup-* folders (delete those by hand if you like).'
