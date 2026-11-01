@echo off
rem Installs df-ai into Dwarf Fortress (see README-FIRST.txt).
rem If it can't find the game: INSTALL.bat -DfDir "D:\Games\Dwarf Fortress"
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
