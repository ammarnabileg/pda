# One-time setup of the Tamween server on a Windows 10/11 PC.
# Run it with setup.bat (it asks for administrator rights). Safe to run again:
# every step checks what already exists and skips it.
#
#   1. Python 3.12 and PostgreSQL 16 (installed with winget if missing)
#   2. Database "tamween" and the server/.env file
#   3. Python packages
#   4. Firewall rule for port 9001 (local network only)
#   5. Daily backup task at 23:15 and a desktop shortcut to start the server
$ErrorActionPreference = "Stop"
$Server = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvFile = Join-Path $Server ".env"
$Port = 9001
$BackupDir = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "Tamween_Backups"

function Step($t) { Write-Host "`n== $t" -ForegroundColor Cyan }
function Ok($t) { Write-Host "   $t" -ForegroundColor Green }

function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}

function Find-Python {
    Refresh-Path
    $c = @(
        "$env:ProgramFiles\Python312\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($c) { return $c }
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($py) {
        $p = & $py.Source -3 -c "import sys; print(sys.executable)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $p) { return $p.Trim() }
    }
    $p = Get-Command python.exe -ErrorAction SilentlyContinue
    # Skip the Microsoft Store stub, which only opens the Store.
    if ($p -and $p.Source -notlike "*WindowsApps*") { return $p.Source }
    return $null
}

function Find-PgBin {
    Get-ChildItem "$env:ProgramFiles\PostgreSQL" -Directory -ErrorAction SilentlyContinue |
        Sort-Object { [int]($_.Name -replace '\D', '0') } -Descending |
        ForEach-Object { Join-Path $_.FullName "bin" } |
        Where-Object { Test-Path (Join-Path $_ "psql.exe") } | Select-Object -First 1
}

function New-Password {
    # Letters and digits only, so it can go into a URL without escaping.
    $chars = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789".ToCharArray()
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

function Need-Winget {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw "winget is not available. Install 'App Installer' from the Microsoft Store, or install Python 3.12 and PostgreSQL 16 by hand, then run setup again."
    }
}

# ---------------------------------------------------------------- 1. Python
Step "Python"
$Python = Find-Python
if ($Python) {
    Ok "found: $Python"
} else {
    Need-Winget
    Write-Host "   installing Python 3.12 ..."
    winget install --id Python.Python.3.12 -e --scope machine --silent --accept-package-agreements --accept-source-agreements
    $Python = Find-Python
    if (-not $Python) { throw "Python was installed but cannot be found. Restart the PC and run setup again." }
    Ok "installed: $Python"
}

# ---------------------------------------------------------------- 1. PostgreSQL
Step "PostgreSQL"
$PgBin = Find-PgBin
$PgPassword = $null
if ($PgBin) {
    Ok "found: $PgBin"
} else {
    Need-Winget
    $PgPassword = New-Password
    Write-Host "   installing PostgreSQL 16 (takes a few minutes) ..."
    winget install --id PostgreSQL.PostgreSQL.16 -e --silent --accept-package-agreements --accept-source-agreements `
        --override "--mode unattended --unattendedmodeui none --superpassword $PgPassword --serverport 5432 --disable-components stackbuilder"
    $PgBin = Find-PgBin
    if (-not $PgBin) { throw "PostgreSQL was installed but cannot be found. Restart the PC and run setup again." }
    Ok "installed: $PgBin"
}
# pg_dump on PATH for backups.
$MachinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($MachinePath -notlike "*$PgBin*") {
    [Environment]::SetEnvironmentVariable("Path", "$MachinePath;$PgBin", "Machine")
    Refresh-Path
}
$Psql = Join-Path $PgBin "psql.exe"

# Make sure the service is running.
$Svc = Get-Service -Name "postgresql*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($Svc) {
    Set-Service $Svc.Name -StartupType Automatic
    if ($Svc.Status -ne "Running") { Start-Service $Svc.Name }
    Ok "service $($Svc.Name) is running and starts with Windows"
}

# ---------------------------------------------------------------- 2. .env and database
Step "Database"
if (Test-Path $EnvFile) {
    Ok ".env already exists, keeping it"
    $line = Get-Content $EnvFile | Where-Object { $_ -match '^DATABASE_URL=' } | Select-Object -First 1
    if ($line -match '://([^:]+):([^@]+)@') { $PgUser = $Matches[1]; $PgPassword = [Uri]::UnescapeDataString($Matches[2]) }
    else { throw "Could not read DATABASE_URL from $EnvFile" }
} else {
    $PgUser = "postgres"
    if (-not $PgPassword) {
        $s = Read-Host "PostgreSQL was already installed. Type the password of the 'postgres' user" -AsSecureString
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
        try { $PgPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    }
}

$env:PGPASSWORD = $PgPassword
try {
    $ok = $false
    for ($i = 0; $i -lt 30; $i++) {
        & $Psql -h localhost -U $PgUser -d postgres -tAc "SELECT 1" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $ok = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $ok) { throw "Cannot log in to PostgreSQL as '$PgUser'. Is the password right and the service running?" }
    $exists = & $Psql -h localhost -U $PgUser -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='tamween'"
    if ($exists -eq "1") {
        Ok "database 'tamween' already exists"
    } else {
        & $Psql -h localhost -U $PgUser -d postgres -c "CREATE DATABASE tamween ENCODING 'UTF8' TEMPLATE template0" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not create the database." }
        Ok "database 'tamween' created"
    }
} finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}

if (-not (Test-Path $EnvFile)) {
    $enc = [Uri]::EscapeDataString($PgPassword)
    @(
        "DATABASE_URL=postgresql+psycopg://${PgUser}:$enc@localhost:5432/tamween",
        "PORT=$Port",
        "TZ_NAME=Asia/Kuwait"
    ) | Set-Content $EnvFile -Encoding ASCII
    # Only administrators and this user can read the file with the database password.
    $User = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    icacls $EnvFile /inheritance:r /grant:r "${User}:F" "*S-1-5-32-544:F" "*S-1-5-18:F" | Out-Null
    Ok ".env written"
}

# ---------------------------------------------------------------- 3. Python packages
Step "Python packages"
$Venv = Join-Path $Server ".venv"
$VenvPy = Join-Path $Venv "Scripts\python.exe"
if (-not (Test-Path $VenvPy)) { & $Python -m venv $Venv; if ($LASTEXITCODE -ne 0) { throw "Could not create the Python environment." } }
& $VenvPy -m pip install --quiet --upgrade pip
& $VenvPy -m pip install --quiet -r (Join-Path $Server "requirements.txt")
if ($LASTEXITCODE -ne 0) { throw "Installing packages failed. Check the internet connection and run setup again." }
Push-Location $Server
try {
    & $VenvPy -c "from app.db import init_db; init_db(); print('tables ready')"
    if ($LASTEXITCODE -ne 0) { throw "The server could not connect to the database." }
} finally { Pop-Location }
Ok "packages installed, tables created"

# ---------------------------------------------------------------- 4. Firewall
Step "Firewall"
$RuleName = "Tamween server (port $Port)"
if (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue) {
    Ok "rule already exists"
} else {
    # All network profiles (co-op Wi-Fi is often marked "Public"), but only devices on the same local network.
    New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Protocol TCP -LocalPort $Port `
        -RemoteAddress LocalSubnet -Action Allow -Profile Any | Out-Null
    Ok "port $Port opened for the local network only"
}

# ---------------------------------------------------------------- 5. Backups and shortcut
Step "Daily backup"
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
$TaskName = "Tamween daily backup"
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Ok "task already exists"
} else {
    $action = New-ScheduledTaskAction -Execute $VenvPy -Argument "scripts\backup.py --dir `"$BackupDir`"" -WorkingDirectory $Server
    $trigger = New-ScheduledTaskTrigger -Daily -At "23:15"
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -User "SYSTEM" -RunLevel Highest | Out-Null
    Ok "every day at 23:15 (or at next start-up if the PC was off) into $BackupDir"
}
Push-Location $Server
try {
    & $VenvPy scripts\backup.py --dir $BackupDir
    if ($LASTEXITCODE -eq 0) { Ok "first backup done" } else { Write-Host "   first backup failed; check pg_dump" -ForegroundColor Yellow }
} finally { Pop-Location }

Step "Desktop shortcut"
$Lnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "تشغيل تموين.lnk"
$sh = New-Object -ComObject WScript.Shell
$sc = $sh.CreateShortcut($Lnk)
$sc.TargetPath = Join-Path $Server "start.bat"
$sc.WorkingDirectory = $Server
$sc.Save()
Ok "created: $Lnk"

# ---------------------------------------------------------------- done
$Ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" -and $_.PrefixOrigin -ne "WellKnown" } |
    Select-Object -First 1).IPAddress
Write-Host "`nSetup finished." -ForegroundColor Green
Write-Host "  Start the server: double-click 'تشغيل تموين' on the desktop."
Write-Host "  Dashboard on this PC:  http://localhost:$Port"
Write-Host "  Address for devices:   $Ip   (make it fixed in the router, see README)"
Write-Host "  Backups:               $BackupDir  (copy them to a USB drive or Google Drive too)"
if ($PgPassword -and -not $exists) {
    Write-Host "`n  The PostgreSQL password is saved in server\.env. Keep a copy in a safe place." -ForegroundColor Yellow
}
