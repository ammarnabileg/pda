# Creates the Android signing key ONCE, in its own protected folder:
#   Documents\Tamween_Signing_Key\
#     tamween.jks                  the key (back it up: USB drive / password manager)
#     ANDROID_KEYSTORE_BASE64.txt  paste into the GitHub secret, then delete
#     README.txt                   what to put in GitHub and how to keep it safe
# Passwords are never written to disk.
# Run: double-click make-signing-key.bat
$ErrorActionPreference = "Stop"
$Folder = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "Tamween_Signing_Key"
$Alias = "tamween"
$Keystore = Join-Path $Folder "tamween.jks"
$B64File = Join-Path $Folder "ANDROID_KEYSTORE_BASE64.txt"

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
Write-Host "Using keytool: $Keytool" -ForegroundColor DarkGray

# Never overwrite: a new key breaks app updates on every device.
if (Test-Path $Folder) { throw "Folder already exists: $Folder`nIf you already have a key, keep using it. Move the folder away only if you are sure." }

function Read-Password($Message) {
    $s = Read-Host $Message -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
$Pw = Read-Password "Key password (8+ characters)"
if ($Pw -ne (Read-Password "Repeat password")) { throw "Passwords do not match." }
if ($Pw.Length -lt 8) { throw "Password must be at least 8 characters." }

New-Item -ItemType Directory -Path $Folder | Out-Null
# Only the current Windows user can open the folder.
$User = [Security.Principal.WindowsIdentity]::GetCurrent().Name
icacls $Folder /inheritance:r /grant:r "${User}:(OI)(CI)F" | Out-Null

# The password goes to keytool through an environment variable: never to a file.
$env:TAMWEEN_KEY_PW = $Pw
try {
    Write-Host "Creating key..." -ForegroundColor Yellow
    & $Keytool -genkeypair -keystore $Keystore -storetype PKCS12 -alias $Alias -keyalg RSA -keysize 2048 -validity 10000 `
        -storepass:env TAMWEEN_KEY_PW -keypass:env TAMWEEN_KEY_PW -dname "CN=Tamween, O=Tamween, L=Kuwait, C=KW" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "keytool failed to create the key." }

    Write-Host "Verifying key..." -ForegroundColor Yellow
    $List = & $Keytool -list -v -keystore $Keystore -storepass:env TAMWEEN_KEY_PW 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not read the new key back." }
    $Sha256 = ($List | Select-String "SHA256:" | Select-Object -First 1).ToString().Trim()
    $Until = ($List | Select-String "until:" | Select-Object -First 1).ToString().Trim()
} finally {
    Remove-Item Env:TAMWEEN_KEY_PW -ErrorAction SilentlyContinue
    $Pw = $null
}

Write-Host "Writing base64..." -ForegroundColor Yellow
[IO.File]::WriteAllText($B64File, [Convert]::ToBase64String([IO.File]::ReadAllBytes($Keystore)), [Text.Encoding]::ASCII)

@"
Tamween Android signing key
===========================
Created:   $(Get-Date -Format "yyyy-MM-dd HH:mm")
File:      tamween.jks (PKCS12, RSA 2048)
Alias:     $Alias
$Until
Fingerprint $Sha256

GitHub > repository > Settings > Secrets and variables > Actions > New repository secret
  ANDROID_KEYSTORE_BASE64    = the whole content of ANDROID_KEYSTORE_BASE64.txt
  ANDROID_KEYSTORE_PASSWORD  = the password you typed (it is NOT saved anywhere)
  ANDROID_KEY_ALIAS          = $Alias

After adding the secrets:
  1. Delete ANDROID_KEYSTORE_BASE64.txt.
  2. Copy tamween.jks to a USB drive or a password manager. Store the password there too.
  3. Never put tamween.jks or the password in Git, WhatsApp, e-mail or chat.

If this key or its password is lost, installed devices cannot be updated:
the app would have to be removed first, losing sales not yet sent to the server.
"@ | Set-Content (Join-Path $Folder "README.txt") -Encoding UTF8

Write-Host "`nSUCCESS: key created and verified." -ForegroundColor Green
Get-ChildItem $Folder | Select-Object Name, Length | Format-Table -AutoSize
Write-Host "Folder: $Folder" -ForegroundColor Cyan
Write-Host "Next: open README.txt in that folder." -ForegroundColor Cyan
Start-Process explorer.exe $Folder
