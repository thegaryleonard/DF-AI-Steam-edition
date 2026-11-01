@echo off
rem Removes df-ai from Dwarf Fortress. Your saves are not touched.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
echo.
pause
