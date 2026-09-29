# Install the OrbitOrc agent into this user's interactive session on Windows.
#
# A scheduled task that runs AT LOGON, AS THE INTERACTIVE USER, not a Windows service. A service runs in
# session 0, which has no window station an application can present into: a rendering job launched from
# one draws nothing and reports success. A task with -LogonType Interactive runs in the logged-in
# session, which is what the agent's session check looks for.
#
#   install\windows-install.ps1 -Release C:\orbitorc\orbitorc_agent
#
# The release directory comes from `mix release orbitorc_agent` built on a Windows machine.
param(
  [Parameter(Mandatory = $true)][string]$Release
)

$ErrorActionPreference = 'Stop'
$bin = Join-Path $Release 'bin\orbitorc_agent.bat'
if (-not (Test-Path $bin)) { throw "no executable at $bin" }

$configDir = Join-Path $env:LOCALAPPDATA 'orbitorc'
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
if (-not (Test-Path (Join-Path $configDir 'config.json'))) {
  throw "write $configDir\config.json first (see install\config.example.json)"
}

$action  = New-ScheduledTaskAction -Execute $bin -Argument 'start' -WorkingDirectory $Release
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName 'OrbitOrc Agent' -Action $action -Trigger $trigger `
  -Settings $settings -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName 'OrbitOrc Agent'

Write-Host "installed: scheduled task 'OrbitOrc Agent' (interactive session, at logon)"
Write-Host "The agent will appear in the fleet within a few seconds if the control plane is reachable."
Write-Host "Auto-login on this box is what keeps a graphical session available after a reboot."
