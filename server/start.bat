@echo off
REM Double-click to start the Tamween server. Keep this window open while the co-op is working.
cd /d "%~dp0"
if not exist .venv (
  echo First run: installing...
  py -3 -m venv .venv || python -m venv .venv
  .venv\Scripts\python -m pip install -r requirements.txt
)
.venv\Scripts\python run.py
pause
