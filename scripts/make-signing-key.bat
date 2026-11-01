@echo off
REM Creates the Android signing key ONCE and prints the 3 GitHub secrets. Needs Java (keytool).
setlocal
set OUT=tamween.jks
where keytool >nul 2>nul || (echo keytool not found. Install Java 17 or Android Studio first. & pause & exit /b 1)
if exist %OUT% (echo %OUT% already exists. Not overwriting it: replacing the key breaks app updates. & pause & exit /b 1)
powershell -NoProfile -Command ^
  "$p1 = Read-Host 'Key password (8+ characters)' -AsSecureString; $p2 = Read-Host 'Repeat password' -AsSecureString;" ^
  "$a = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1));" ^
  "$b = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2));" ^
  "if ($a -ne $b) { Write-Host 'Passwords do not match.'; exit 1 }; if ($a.Length -lt 8) { Write-Host 'Password must be at least 8 characters.'; exit 1 };" ^
  "& keytool -genkeypair -keystore '%OUT%' -storetype PKCS12 -alias tamween -keyalg RSA -keysize 2048 -validity 10000 -storepass $a -keypass $a -dname 'CN=Tamween, O=Tamween, C=KW' | Out-Null;" ^
  "if ($LASTEXITCODE -ne 0) { exit 1 };" ^
  "[IO.File]::WriteAllText('%OUT%.b64', [Convert]::ToBase64String([IO.File]::ReadAllBytes('%OUT%')))"
if errorlevel 1 (pause & exit /b 1)
echo.
echo Created %OUT% and %OUT%.b64
echo Add these in GitHub: Settings ^> Secrets and variables ^> Actions ^> New repository secret
echo   ANDROID_KEYSTORE_BASE64   = contents of %OUT%.b64
echo   ANDROID_KEYSTORE_PASSWORD = the password you just typed
echo   ANDROID_KEY_ALIAS         = tamween
echo.
echo Keep %OUT% and the password somewhere safe. Delete %OUT%.b64 after adding the secret. Never commit either file.
pause
