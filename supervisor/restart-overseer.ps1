# Restart the overseer console (supervisor/overseer.py on :8767)
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'overseer\.py' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
$py = $null
$pyfile = Join-Path $PSScriptRoot 'python.txt'
if (Test-Path $pyfile) { $py = (Get-Content $pyfile -Raw).Trim() }
if (-not $py -or -not (Test-Path $py)) { $py = 'C:\Users\dad\AppData\Local\Python\pythoncore-3.15-64\python.exe' }
if (-not (Test-Path $py)) { $py = (Get-Command python -ErrorAction SilentlyContinue).Source }
Start-Process -WindowStyle Hidden -FilePath cmd -ArgumentList '/c',"`"`"$py`" -u overseer.py >> logs\overseer.log 2>&1`"" -WorkingDirectory $PSScriptRoot
