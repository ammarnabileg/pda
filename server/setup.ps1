# One-time setup of the Tamween server on a Windows 10/11 PC.
# Run it with setup.bat (asks for administrator rights). Safe to run again: each step
# checks what exists and skips it. Any failed step stops the setup with the reason.
#
#   1. Python 3.11+ and PostgreSQL 16 (winget if missing)
#   2. A dedicated database user "tamween_app" that owns only the "tamween" database
#   3. server\.env and server\.secrets (both readable only by admins, SYSTEM and you)
#   4. Python packages and tables
#   5. Verified backup (dump + restore test), daily backup task that is run once now
#   6. Server as a Windows task that starts with the PC, firewall rule, desktop shortcut
$ErrorActionPreference = "Stop"
$Server = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvFile = Join-Path $Server ".env"
$SecretsDir = Join-Path $Server ".secrets"
$SuperFile = Join-Path $SecretsDir "pg-superuser.txt"
$LogDir = Join-Path $Server "logs"
$Port = 9001
$AppUser = "tamween_app"
$AppDb = "tamween"
$BackupDir = Join-Path $env:ProgramData "Tamween\Backups"

function Step($t) { Write-Host "`n== $t" -ForegroundColor Cyan }
function Ok($t) { Write-Host "   $t" -ForegroundColor Green }
function Warn($t) { Write-Host "   $t" -ForegroundColor Yellow }

# Runs a native program and stops the setup if it fails.
function Exec([string]$What, [scriptblock]$Cmd) {
    $ErrorActionPreference = "Continue"
    $out = & $Cmd 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE): $($out | Out-String)" }
    return $out
}

# Only Administrators, SYSTEM and the current user can read the path.
function Protect([string]$Path) {
    $ErrorActionPreference = "Continue"
    $User = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $f = if (Test-Path $Path -PathType Container) { "(OI)(CI)F" } else { "F" }
    $out = icacls $Path /inheritance:r /grant:r "${User}:$f" "*S-1-5-32-544:$f" "*S-1-5-18:$f" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not restrict access to ${Path}: $out" }
    # Check: no "Users" or "Everyone" entry may remain.
    $acl = (Get-Acl $Path).Access | ForEach-Object { $_.IdentityReference.Value }
    if ($acl | Where-Object { $_ -match 'Users$|Everyone|Authenticated' }) { throw "Access to $Path is still open to other users." }
}

function New-Password {
    # Letters and digits only, so it can go into a URL without escaping.
    $chars = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789".ToCharArray()
    $bytes = New-Object byte[] 28
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}

function Need-Winget {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw "winget is not available. Install 'App Installer' from the Microsoft Store (or install Python 3.12 / PostgreSQL 16 by hand) and run setup again."
    }
}

function Winget-Install([string]$Id, [string[]]$Extra) {
    Need-Winget
    $ErrorActionPreference = "Continue"
    & winget install --id $Id -e --silent --accept-package-agreements --accept-source-agreements @Extra
    # 0 = installed; -1978335189 (0x8A15002B) = already installed / no newer version.
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) { throw "winget could not install $Id (exit $LASTEXITCODE)." }
}

# ---------------------------------------------------------------- Python
function Python-Ok([string]$Exe) {
    $ErrorActionPreference = "Continue"
    if (-not $Exe -or -not (Test-Path $Exe) -or $Exe -like "*WindowsApps*") { return $false }
    & $Exe -c "import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)" 2>$null
    return $LASTEXITCODE -eq 0
}

function Find-Python {
    $ErrorActionPreference = "Continue"
    Refresh-Path
    $c = @("$env:ProgramFiles\Python312\python.exe", "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe")
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($py) { $p = & $py.Source -3.12 -c "import sys; print(sys.executable)" 2>$null; if ($LASTEXITCODE -eq 0) { $c += $p.Trim() } }
    $p = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($p) { $c += $p.Source }
    return $c | Where-Object { Python-Ok $_ } | Select-Object -First 1
}

Step "Python"
$Python = Find-Python
if (-not $Python) {
    Write-Host "   installing Python 3.12 ..."
    Winget-Install "Python.Python.3.12" @("--scope", "machine")
    $Python = Find-Python
    if (-not $Python) { throw "Python 3.12 was installed but cannot be found. Restart the PC and run setup again." }
}
Ok "$Python ($(& $Python --version))"

# ---------------------------------------------------------------- Secrets folder
New-Item -ItemType Directory -Force -Path $SecretsDir, $LogDir | Out-Null
Protect $SecretsDir

function Read-Secret([string]$Prompt) {
    $s = Read-Host $Prompt -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

# ---------------------------------------------------------------- PostgreSQL
# The EDB installer records each installation in the registry, with its service and port.
function Find-Postgres {
    $list = foreach ($k in Get-ChildItem "HKLM:\SOFTWARE\PostgreSQL\Installations" -ErrorAction SilentlyContinue) {
        $i = Get-ItemProperty $k.PSPath
        $svcKey = "HKLM:\SOFTWARE\PostgreSQL\Services\$($i.'Service ID')"
        $port = (Get-ItemProperty $svcKey -ErrorAction SilentlyContinue).Port
        $bin = Join-Path $i.'Base Directory' "bin"
        if (Test-Path (Join-Path $bin "psql.exe")) {
            [pscustomobject]@{ Version = [version]($i.Version -replace '[^\d.]', ''); Bin = $bin; Service = $i.'Service ID'; Port = $(if ($port) { [int]$port } else { 5432 }) }
        }
    }
    return $list | Sort-Object Version -Descending | Select-Object -First 1
}

Step "PostgreSQL"
$Pg = Find-Postgres
if (-not $Pg) {
    if (Get-ChildItem "$env:ProgramFiles\PostgreSQL" -ErrorAction SilentlyContinue) {
        throw "A PostgreSQL folder exists but no registered installation was found. Repair or remove it, then run setup again."
    }
    # The superuser password is saved BEFORE installing, so a crash later never loses it.
    $SuperPw = New-Password
    Set-Content $SuperFile "postgres`n$SuperPw" -Encoding ASCII -NoNewline
    Write-Host "   installing PostgreSQL 16 (a few minutes) ..."
    Winget-Install "PostgreSQL.PostgreSQL.16" @("--override", "--mode unattended --unattendedmodeui none --superpassword $SuperPw --serverport 5432 --disable-components stackbuilder")
    $Pg = Find-Postgres
    if (-not $Pg) { throw "PostgreSQL was installed but is not registered. Restart the PC and run setup again." }
}
$Svc = Get-Service -Name $Pg.Service -ErrorAction SilentlyContinue
if (-not $Svc) { throw "PostgreSQL $($Pg.Version) has no Windows service named '$($Pg.Service)'." }
Set-Service $Svc.Name -StartupType Automatic
if ($Svc.Status -ne "Running") { Start-Service $Svc.Name; (Get-Service $Svc.Name).WaitForStatus("Running", "00:01:00") }
Ok "PostgreSQL $($Pg.Version), service $($Pg.Service), port $($Pg.Port)"

$MachinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($MachinePath -notlike "*$($Pg.Bin)*") { [Environment]::SetEnvironmentVariable("Path", "$MachinePath;$($Pg.Bin)", "Machine") }
Refresh-Path
$Psql = Join-Path $Pg.Bin "psql.exe"

# ---------------------------------------------------------------- Database and user
Step "Database"
# Connection settings: from .env if it exists (respected in full), otherwise this PostgreSQL.
$DbHost = "localhost"; $DbPort = $Pg.Port; $DbName = $AppDb; $AppPw = $null; $EnvUser = $null
if (Test-Path $EnvFile) {
    $line = Get-Content $EnvFile | Where-Object { $_ -match '^DATABASE_URL=' } | Select-Object -First 1
    if ($line -notmatch '^DATABASE_URL=[^:]+://([^:]+):([^@]+)@([^:/]+)(?::(\d+))?/([^?\s]+)') { throw "Cannot read DATABASE_URL in $EnvFile." }
    $EnvUser = [Uri]::UnescapeDataString($Matches[1]); $EnvPw = [Uri]::UnescapeDataString($Matches[2])
    $DbHost = $Matches[3]; $DbPort = $(if ($Matches[4]) { [int]$Matches[4] } else { 5432 }); $DbName = $Matches[5]
    if ($EnvUser -eq $AppUser) { $AppPw = $EnvPw }
    Ok ".env found: $EnvUser@${DbHost}:$DbPort/$DbName"
}
if ($DbHost -notin @("localhost", "127.0.0.1") -or $DbPort -ne $Pg.Port) {
    throw ".env points to ${DbHost}:$DbPort but this PC's PostgreSQL is on localhost:$($Pg.Port). Fix .env by hand; setup will not touch another server."
}

# Superuser login: saved file, else the old .env if it used postgres, else ask.
$SuperUser = "postgres"
if (Test-Path $SuperFile) { $SuperUser, $SuperPw = (Get-Content $SuperFile -Raw) -split "`n", 2 }
elseif ($EnvUser -eq "postgres") { $SuperPw = $EnvPw }
else { $SuperPw = Read-Secret "PostgreSQL was installed before. Type the password of the 'postgres' user" }

function Psql([string]$Db, [string]$Sql) {
    $env:PGPASSWORD = $SuperPw
    try { (Exec "psql ($Sql)" { & $Psql -h $DbHost -p $DbPort -U $SuperUser -d $Db -q -v ON_ERROR_STOP=1 -tAc $Sql } |
        Where-Object { $_ -and $_ -notmatch '^(NOTICE|WARNING):' } | Select-Object -Last 1) }
    finally { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue }
}

$env:PGPASSWORD = $SuperPw
$ErrorActionPreference = "Continue"
& $Psql -h $DbHost -p $DbPort -U $SuperUser -d postgres -tAc "SELECT 1" 2>$null | Out-Null
$loginOk = $LASTEXITCODE -eq 0
$ErrorActionPreference = "Stop"
Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
if (-not $loginOk) { throw "Cannot log in to PostgreSQL as '$SuperUser'. Check the password and run setup again." }
# Keep the working superuser login so backups can run a restore test and a rerun never asks again.
Set-Content $SuperFile "$SuperUser`n$SuperPw" -Encoding ASCII -NoNewline

if (-not $AppPw) { $AppPw = New-Password }
$roleExists = (Psql "postgres" "SELECT 1 FROM pg_roles WHERE rolname='$AppUser'") -eq "1"
if ($roleExists) { Psql "postgres" "ALTER ROLE $AppUser LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '$AppPw'" | Out-Null }
else { Psql "postgres" "CREATE ROLE $AppUser LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '$AppPw'" | Out-Null }
if ((Psql "postgres" "SELECT 1 FROM pg_database WHERE datname='$DbName'") -ne "1") {
    Psql "postgres" "CREATE DATABASE $DbName OWNER $AppUser ENCODING 'UTF8' TEMPLATE template0" | Out-Null
}
Psql "postgres" "ALTER DATABASE $DbName OWNER TO $AppUser" | Out-Null
Psql "postgres" "REVOKE ALL ON DATABASE $DbName FROM PUBLIC" | Out-Null
# Tables made earlier by 'postgres' (old setups) move to the app user.
Psql $DbName @"
DO `$`$ DECLARE r record; BEGIN
  ALTER SCHEMA public OWNER TO $AppUser;
  FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
    EXECUTE format('ALTER TABLE public.%I OWNER TO $AppUser', r.tablename); END LOOP;
  FOR r IN SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema = 'public' LOOP
    EXECUTE format('ALTER SEQUENCE public.%I OWNER TO $AppUser', r.sequence_name); END LOOP;
END `$`$
"@ | Out-Null
Ok "user '$AppUser' owns database '$DbName' (no admin rights)"

if (Test-Path $EnvFile) { Copy-Item $EnvFile (Join-Path $SecretsDir ".env.before-setup-$(Get-Date -Format yyyyMMddHHmmss)") }
$other = @()
if (Test-Path $EnvFile) { $other = Get-Content $EnvFile | Where-Object { $_ -notmatch '^(DATABASE_URL|PORT|TZ_NAME)=' } }
@("DATABASE_URL=postgresql+psycopg://${AppUser}:$AppPw@${DbHost}:$DbPort/$DbName", "PORT=$Port", "TZ_NAME=Asia/Kuwait") + $other |
    Set-Content $EnvFile -Encoding ASCII
Protect $EnvFile
Ok ".env written and locked"

# ---------------------------------------------------------------- Python packages
Step "Python packages"
$Venv = Join-Path $Server ".venv"
$VenvPy = Join-Path $Venv "Scripts\python.exe"
if (-not (Python-Ok $VenvPy)) {
    if (Test-Path $Venv) { Remove-Item $Venv -Recurse -Force }
    Exec "Creating the Python environment" { & $Python -m venv $Venv } | Out-Null
}
Exec "Updating pip" { & $VenvPy -m pip install --quiet --upgrade pip } | Out-Null
Exec "Installing packages (check the internet connection)" { & $VenvPy -m pip install --quiet -r (Join-Path $Server "requirements.txt") } | Out-Null
Push-Location $Server
try { Exec "Creating tables as $AppUser" { & $VenvPy -c "from app.db import init_db; init_db()" } | Out-Null } finally { Pop-Location }
Ok "packages installed, tables ready"

# ---------------------------------------------------------------- Backups
Step "Backup"
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
Protect (Split-Path $BackupDir)
$BackupLog = Join-Path $BackupDir "backup.log"
Push-Location $Server
try { Exec "Backup with restore test" { & $VenvPy scripts\backup.py --dir $BackupDir --restore-test } | ForEach-Object { Ok $_ } }
finally { Pop-Location }

$BackupTask = "Tamween daily backup"
$wrapper = Join-Path $Server "backup-task.cmd"
# backup.py reads the superuser login for its restore test from .secrets itself; the task holds no secret.
@"
@echo off
cd /d "$Server"
"$VenvPy" scripts\backup.py --dir "$BackupDir" --restore-test
"@ | Set-Content $wrapper -Encoding ASCII
Unregister-ScheduledTask -TaskName $BackupTask -Confirm:$false -ErrorAction SilentlyContinue
$action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$wrapper`""
$trigger = New-ScheduledTaskTrigger -Daily -At "23:15"
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
Register-ScheduledTask -TaskName $BackupTask -Action $action -Trigger $trigger -Settings $settings -User "SYSTEM" -RunLevel Highest | Out-Null
# Prove the task itself works (as SYSTEM, with its own PATH), not just that it was created.
Start-ScheduledTask -TaskName $BackupTask
$deadline = (Get-Date).AddMinutes(5)
do { Start-Sleep 3; $t = Get-ScheduledTask -TaskName $BackupTask } while ($t.State -eq "Running" -and (Get-Date) -lt $deadline)
$result = (Get-ScheduledTaskInfo -TaskName $BackupTask).LastTaskResult
if ($result -ne 0) { throw "The scheduled backup failed when run as a task (result $result). See $BackupLog" }
Ok "daily at 23:15 (or at next start-up if the PC was off); test run as a task OK"
Ok "log: $BackupLog"

# ---------------------------------------------------------------- Server as a Windows task
Step "Server"
$ServerTask = "Tamween server"
$runCmd = Join-Path $Server "server-task.cmd"
@"
@echo off
cd /d "$Server"
"$VenvPy" run.py >> "$LogDir\server.log" 2>&1
"@ | Set-Content $runCmd -Encoding ASCII
Unregister-ScheduledTask -TaskName $ServerTask -Confirm:$false -ErrorAction SilentlyContinue
$action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$runCmd`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $ServerTask -Action $action -Trigger $trigger -Settings $settings -User "SYSTEM" -RunLevel Highest | Out-Null
Stop-ScheduledTask -TaskName $ServerTask -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName $ServerTask
$up = $false
for ($i = 0; $i -lt 40 -and -not $up; $i++) {
    Start-Sleep 2
    try { $up = (Invoke-RestMethod "http://localhost:$Port/api/v1/ping" -TimeoutSec 3).app -eq "tamween" } catch {}
}
if (-not $up) { throw "The server did not start. See $LogDir\server.log" }
Ok "running, and starts automatically with Windows (restarts if it stops)"

# ---------------------------------------------------------------- Network
Step "Network"
$route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
$Ip = $null
if ($route) {
    $Ip = (Get-NetIPAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
    $prof = Get-NetConnectionProfile -InterfaceIndex $route.ifIndex -ErrorAction SilentlyContinue
    if ($prof -and $prof.NetworkCategory -eq "Public") {
        Warn "Windows marks this network ('$($prof.Name)') as Public, so devices cannot reach the server."
        $ans = Read-Host "   Is this the co-op's own private network (not a customer or public Wi-Fi)? Mark it Private? (y/n)"
        if ($ans -match '^[yY]') { Set-NetConnectionProfile -InterfaceIndex $route.ifIndex -NetworkCategory Private; Ok "marked Private" }
        else { Warn "left as Public: devices will not connect until the network is Private." }
    }
}
$RuleName = "Tamween server (port $Port)"
Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Protocol TCP -LocalPort $Port `
    -RemoteAddress LocalSubnet -Action Allow -Profile Domain, Private | Out-Null
Ok "port $Port open on Private/Domain networks, same local network only"

# ---------------------------------------------------------------- Shortcut
$Lnk = Join-Path ([Environment]::GetFolderPath("CommonDesktopDirectory")) "لوحة تموين.url"
"[InternetShortcut]`r`nURL=http://localhost:$Port/`r`n" | Set-Content $Lnk -Encoding ASCII
Ok "desktop shortcut 'لوحة تموين' opens the dashboard"

Write-Host "`nSetup finished. Everything above was checked." -ForegroundColor Green
Write-Host "  Dashboard on this PC:  http://localhost:$Port"
Write-Host "  Address for devices:   $Ip   (reserve this IP in the router so it never changes)"
Write-Host "  Backups:               $BackupDir   (copy them to a USB drive or cloud weekly)"
Write-Host "  Logs:                  $LogDir\server.log, $BackupLog"
Write-Host "  Database passwords:    $SecretsDir  (locked to administrators)"
