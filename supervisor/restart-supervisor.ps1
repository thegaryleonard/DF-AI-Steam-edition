# Restart the game manager (supervisor/dfai_supervisor.py), e.g. after editing it.
# Only the manager: the game, the overlay and the desk keep running.
Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^python' -and $_.CommandLine -match 'dfai_supervisor\.py' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
Start-Process -WindowStyle Minimized -FilePath cmd -ArgumentList '/c','C:\Users\dad\AppData\Local\Python\pythoncore-3.15-64\python.exe -u dfai_supervisor.py >> logs\supervisor.log 2>&1' -WorkingDirectory 'C:\Users\dad\dfai-stream\df-ai\supervisor'
