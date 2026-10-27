# Restart the overseer console (supervisor/overseer.py on :8767)
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'overseer\.py' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
Start-Process -WindowStyle Hidden -FilePath cmd -ArgumentList '/c','C:\Users\dad\AppData\Local\Python\pythoncore-3.15-64\python.exe -u overseer.py >> logs\overseer.log 2>&1' -WorkingDirectory 'C:\Users\dad\dfai-stream\df-ai\supervisor'
