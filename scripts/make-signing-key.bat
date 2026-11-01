@echo off
REM Double-click to create the Android signing key. The work is done in make-signing-key.ps1.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0make-signing-key.ps1"
pause
