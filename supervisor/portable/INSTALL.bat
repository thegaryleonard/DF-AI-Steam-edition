@echo off
rem Installs the df-ai stream package on this PC (see README.txt).
rem Extra options: INSTALL.bat -DfDir "D:\Games\Dwarf Fortress"   (see install.ps1)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
