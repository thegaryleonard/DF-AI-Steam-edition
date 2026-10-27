# Restart the stream page server (supervisor/gamefeed.py on :8766)
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'gamefeed\.py' -and $_.Name -match 'python|cmd' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
Start-Process -WindowStyle Hidden -FilePath cmd -ArgumentList '/c','C:\Users\dad\AppData\Local\Python\pythoncore-3.15-64\python.exe -u gamefeed.py >> logs\gamefeed.log 2>&1' -WorkingDirectory 'C:\Users\dad\dfai-stream\df-ai\supervisor'
