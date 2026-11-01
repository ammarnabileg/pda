# Creates the Android signing key ONCE and writes the base64 for the GitHub secret.
# Run: double-click make-signing-key.bat (or: powershell -ExecutionPolicy Bypass -File make-signing-key.ps1)
$ErrorActionPreference = "Stop"
$Out = Join-Path (Get-Location) "tamween.jks"
$B64 = "$Out.b64"

# keytool is often not on PATH; Android Studio ships its own Java.
$Keytool = (Get-Command keytool.exe -ErrorAction SilentlyContinue).Source
if (-not $Keytool) {
    $Candidates = @()
    if ($env:JAVA_HOME) { $Candidates += Join-Path $env:JAVA_HOME "bin\keytool.exe" }
    $Candidates += @(
        "$env:ProgramFiles\Android\Android Studio\jbr\bin\keytool.exe",
        "$env:ProgramFiles\Android\Android Studio\jre\bin\keytool.exe",
        "$env:LOCALAPPDATA\Programs\Android Studio\jbr\bin\keytool.exe"
    )
    $Candidates += Get-ChildItem "$env:ProgramFiles\Java", "$env:ProgramFiles\Eclipse Adoptium", "$env:ProgramFiles\Microsoft" `
        -Filter keytool.exe -Recurse -ErrorAction SilentlyContinue | ForEach-Object FullName
    $Keytool = $Candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
if (-not $Keytool) { throw "keytool.exe not found. Install Android Studio or Java 17." }
Write-Host "Using $Keytool"

if (Test-Path $Out) { throw "$Out already exists. Not overwriting it: a new key breaks app updates on every device." }

function Read-Password($Message) {
    $s = Read-Host $Message -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
$Pw = Read-Password "Key password (8+ characters)"
if ($Pw -ne (Read-Password "Repeat password")) { throw "Passwords do not match." }
if ($Pw.Length -lt 8) { throw "Password must be at least 8 characters." }

# Passing the password through an environment variable keeps it out of files and the process list.
$env:TAMWEEN_KEY_PW = $Pw
try {
    & $Keytool -genkeypair -keystore $Out -storetype PKCS12 -alias tamween -keyalg RSA -keysize 2048 -validity 10000 `
        -storepass:env TAMWEEN_KEY_PW -keypass:env TAMWEEN_KEY_PW -dname "CN=Tamween, O=Tamween, C=KW"
    if ($LASTEXITCODE -ne 0) { throw "keytool failed." }
    & $Keytool -list -keystore $Out -storepass:env TAMWEEN_KEY_PW | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not read the new key back." }
} finally {
    Remove-Item Env:TAMWEEN_KEY_PW -ErrorAction SilentlyContinue
    $Pw = $null
}
[IO.File]::WriteAllText($B64, [Convert]::ToBase64String([IO.File]::ReadAllBytes($Out)), [Text.Encoding]::ASCII)

Write-Host ""
Write-Host "Created $Out and $B64" -ForegroundColor Green
Write-Host "GitHub > Settings > Secrets and variables > Actions > New repository secret:"
Write-Host "  ANDROID_KEYSTORE_BASE64   = contents of tamween.jks.b64"
Write-Host "  ANDROID_KEYSTORE_PASSWORD = the password you typed"
Write-Host "  ANDROID_KEY_ALIAS         = tamween"
Write-Host "Keep tamween.jks and the password safe. Delete tamween.jks.b64 after adding the secret." -ForegroundColor Yellow
