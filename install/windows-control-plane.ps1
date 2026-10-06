<#
  Install the OrbitOrc control plane on this Windows box: a boot task that runs it as LOCAL SERVICE with no
  logon, and restarts it if it stops.

    powershell -ExecutionPolicy Bypass -File install\windows-control-plane.ps1 -Release C:\path\to\orbitorc
      # the extracted orbitorc-Windows-X64.zip of a release

  Its settings live in C:\ProgramData\orbitorc\control-plane.env, one KEY=value per line; write
  ORBITORC_AGENT_TOKENS (name=token,...) and PHX_HOST (the address the dashboard is opened at) there first.
  SECRET_KEY_BASE is generated on first install and kept. The database lives beside it.

  - LOCAL SERVICE, never SYSTEM: the control plane holds every agent's token and answers the network.
  - RELEASE_DISTRIBUTION=none: no Erlang distribution port and no epmd, so a release's cookie opens nothing.
  - A boot trigger plus a repeat every five minutes: a task that stops is started again without a reboot.
  - The firewall rule admits the port from the local subnet only.

  Run elevated. Re-running replaces the release and the task and keeps the env file and the database.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Release,
    [string]$DataDir = (Join-Path $env:ProgramData 'orbitorc'),
    [int]$Port = 0
)
$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'run elevated' }

$Release = (Resolve-Path $Release).Path
if (-not (Test-Path (Join-Path $Release 'bin\orbitorc.bat'))) { throw "no bin\orbitorc.bat under $Release" }
$account = 'NT AUTHORITY\LOCAL SERVICE'
$envFile = Join-Path $DataDir 'control-plane.env'
$installed = Join-Path $DataDir 'release'
$logs = Join-Path $DataDir 'logs'
$tmp = Join-Path $DataDir 'tmp'

# The data directory: SYSTEM and Administrators full, LOCAL SERVICE modify, nobody else.
New-Item -ItemType Directory -Force -Path $DataDir, $logs, $tmp | Out-Null
$acl = New-Object System.Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
foreach ($id in 'NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators') {
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
}
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($account, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
Set-Acl -Path $DataDir -AclObject $acl

if (-not (Test-Path $envFile)) {
    throw "write $envFile first: ORBITORC_AGENT_TOKENS=name=token,... and PHX_HOST=<address the dashboard is opened at>"
}
$lines = [IO.File]::ReadAllLines($envFile)
$keys = $lines | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object { ($_ -split '=', 2)[0] }
if ($keys -notcontains 'ORBITORC_AGENT_TOKENS') { throw "$envFile needs ORBITORC_AGENT_TOKENS=name=token,..." }
$add = @()
if ($keys -notcontains 'SECRET_KEY_BASE') {
    $bytes = New-Object byte[] 64
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $add += "SECRET_KEY_BASE=$([Convert]::ToBase64String($bytes))"
    'generated SECRET_KEY_BASE'
}
if ($keys -notcontains 'DATABASE_PATH') { $add += "DATABASE_PATH=$(Join-Path $DataDir 'control-plane.db')" }
if ($keys -notcontains 'PORT') { $add += "PORT=$(if ($Port -gt 0) { $Port } else { 4000 })" }
elseif ($Port -gt 0) { $lines = $lines | ForEach-Object { if ($_ -match '^PORT=') { "PORT=$Port" } else { $_ } } }
if ($keys -notcontains 'PHX_HOST') { $add += 'PHX_HOST=localhost' }
if ($keys -notcontains 'RELEASE_DISTRIBUTION') { $add += 'RELEASE_DISTRIBUTION=none' }
if ($keys -notcontains 'RELEASE_TMP') { $add += "RELEASE_TMP=$tmp" }
[IO.File]::WriteAllLines($envFile, @($lines) + $add)
$fileAcl = New-Object System.Security.AccessControl.FileSecurity
$fileAcl.SetAccessRuleProtection($true, $false)
foreach ($id in 'NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators') {
    $fileAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl', 'Allow')))
}
$fileAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($account, 'Read', 'Allow')))
Set-Acl -Path $envFile -AclObject $fileAcl
$port = [int](([IO.File]::ReadAllLines($envFile) | Where-Object { $_ -match '^PORT=' } | Select-Object -First 1) -split '=', 2)[1]

# The release, copied under the data directory so LOCAL SERVICE can read it.
$task = 'OrbitOrc control plane'
if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like "$installed\*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
if ($Release -ne $installed) {
    if (Test-Path $installed) { Remove-Item $installed -Recurse -Force }
    Copy-Item $Release $installed -Recurse
}

# The runner: load the env file into the process, then run the release in the foreground.
$runner = Join-Path $DataDir 'run-control-plane.ps1'
@"
# Generated by install\windows-control-plane.ps1. Runs as LOCAL SERVICE from the boot task.
`$ErrorActionPreference = 'Continue'
foreach (`$line in [IO.File]::ReadAllLines('$envFile')) {
    if (`$line -match '^([A-Z_]+)=(.*)$') { [Environment]::SetEnvironmentVariable(`$Matches[1], `$Matches[2], 'Process') }
}
`$log = Join-Path '$logs' 'control-plane.log'
if ((Test-Path `$log) -and (Get-Item `$log).Length -gt 10MB) { Move-Item `$log "`$log.old" -Force }
Add-Content -Path `$log -Value "`$(Get-Date -Format o) starting"
# Out-File, because Windows PowerShell's redirection operators write UTF-16.
& '$installed\bin\orbitorc.bat' start 2>&1 | Out-File -FilePath `$log -Append -Encoding utf8
Add-Content -Path `$log -Value "`$(Get-Date -Format o) exited `$LASTEXITCODE"
"@ | Set-Content -Path $runner -Encoding utf8

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$runner`""
$boot = New-ScheduledTaskTrigger -AtStartup
$repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
$principal = New-ScheduledTaskPrincipal -UserId $account -LogonType ServiceAccount
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DontStopOnIdleEnd -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $task -Action $action -Trigger @($boot, $repeat) -Principal $principal -Settings $settings -Force `
    -Description "OrbitOrc control plane on port $port, as LOCAL SERVICE. Settings: $envFile. Log: $logs\control-plane.log" | Out-Null

$rule = 'OrbitOrc control plane'
Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -RemoteAddress LocalSubnet -Profile Private, Domain | Out-Null

Start-ScheduledTask -TaskName $task
"installed: $installed"
"task:      $task (boot, every 5 min, as LOCAL SERVICE)"
"env:       $envFile"
"log:       $logs\control-plane.log"
"firewall:  TCP $port from LocalSubnet"
