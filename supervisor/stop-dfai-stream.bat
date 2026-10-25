@echo off
rem Stops the df-ai stream helpers (broadsheet, stream page, chat logger, game
rem manager). Leaves Dwarf Fortress and OBS running: save and quit those yourself.
setlocal
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^(python|python3|py|pythonw)' -and $_.CommandLine -match 'dfai_supervisor.py|overlay.py|lan_proxy.py|gamefeed.py|twitch_chat_log.py|new_fort.py' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; if ('%~1' -ne 'quiet') { 'stopped ' + $_.ProcessId + ' ' + (($_.CommandLine -split ' ')[-1]) } }"
if not "%~1"=="quiet" (
  echo df-ai stream helpers stopped. Dwarf Fortress and OBS are still open.
  timeout /t 10
)
