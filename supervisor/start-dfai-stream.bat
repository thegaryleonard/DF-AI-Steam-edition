@echo off
rem ===================================================================
rem  df-ai stream: starts everything for the unattended Twitch stream
rem    - the Herald broadsheet (http://localhost:8765/), its LAN copy (:8780)
rem    - the one-page stream view (http://localhost:8766/)
rem    - the Twitch chat logger
rem    - the game manager (dfai_supervisor.py), which
rem        * starts Dwarf Fortress through Steam if it isn't running,
rem          loads the newest save and turns df-ai on
rem        * starts OBS streaming if OBS isn't running (and restarts it if it crashes)
rem        * restarts a crashed or frozen game, quicksaves, answers diplomats
rem        * when a fort falls, abandons it and embarks a new one nearby
rem  Close everything with stop-dfai-stream.bat
rem ===================================================================
setlocal
set "DFAI=%~dp0"
if "%DFAI:~-1%"=="\" set "DFAI=%DFAI:~0,-1%"
if not exist "%DFAI%\dfai_supervisor.py" (
  echo Could not find the df-ai supervisor folder. & pause & exit /b 1
)
set "PY="
if exist "%DFAI%\python.txt" set /p PY=<"%DFAI%\python.txt"
if not defined PY set "PY=C:\Users\dad\AppData\Local\Python\pythoncore-3.15-64\python.exe"
if not exist "%PY%" set "PY=python"
set "LOGS=%DFAI%\logs"
if not exist "%LOGS%" mkdir "%LOGS%"

rem don't start a second copy of anything
call "%~dp0stop-dfai-stream.bat" quiet

cd /d "%DFAI%"
echo Starting the broadsheet, stream page, chat logger and game manager from %DFAI%
start "dfai overlay"    /min cmd /c ""%PY%" -u overlay.py            >> "%LOGS%\overlay.log" 2>&1"
start "dfai lan copy"   /min cmd /c ""%PY%" -u lan_proxy.py 8780     >> "%LOGS%\lan_proxy.log" 2>&1"
start "dfai overseer"   /min cmd /c ""%PY%" -u overseer.py          >> "%LOGS%\overseer.log" 2>&1"
start "dfai gamefeed"   /min cmd /c ""%PY%" -u gamefeed.py           >> "%LOGS%\gamefeed.log" 2>&1"
start "dfai twitch log" /min cmd /c ""%PY%" -u twitch_chat_log.py tediusprocesses laserjetlab >> "%LOGS%\twitch.log" 2>&1"
rem give the web pages a moment, then the manager (it launches DF and OBS)
timeout /t 5 /nobreak >nul
start "dfai game manager" /min cmd /c ""%PY%" -u dfai_supervisor.py >> "%LOGS%\supervisor.log" 2>&1"

echo.
echo Running. Broadsheet: http://localhost:8765/   Stream page: http://localhost:8766/
echo The game manager starts Dwarf Fortress and OBS by itself if they aren't open.
echo Logs: %LOGS%
timeout /t 15
