@echo off
REM The server normally runs by itself (Windows task "Tamween server", set up by setup.bat).
REM This file opens the dashboard if it is running, or starts the server in this window if not.
cd /d "%~dp0"
powershell -NoProfile -Command "try { if ((Invoke-RestMethod http://localhost:9001/api/v1/ping -TimeoutSec 3).app -eq 'tamween') { exit 0 } } catch {}; exit 1"
if not errorlevel 1 (
  start "" http://localhost:9001/
  exit /b
)
if not exist .venv (echo Run setup.bat first. & pause & exit /b 1)
echo Starting the server here. Keep this window open.
.venv\Scripts\python run.py
pause
