@echo off
REM Daily backup. Add this file to Windows Task Scheduler (see README).
cd /d "%~dp0"
.venv\Scripts\python scripts\backup.py %*
