# Registers two scheduled tasks so the widget comes back after a reboot, then
# starts both now. Run this ELEVATED (right-click > Run with PowerShell as
# administrator, or from an elevated prompt).
#
# Two tasks rather than one, on purpose:
#   - the sensor service needs administrator rights to read the hardware
#   - the widget only reads a text file, so it runs with normal rights
# Registering the service as a scheduled task with highest privileges also
# means no UAC prompt at every logon.

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    throw 'This script must be run elevated.'
}

$repo    = Split-Path -Parent $PSScriptRoot
$service = Join-Path $repo 'src\sensor-service.ps1'
$widget  = Join-Path $repo 'src\Widget.exe'
$ps51    = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not (Test-Path $widget)) { throw "Widget.exe not found -- run tools\build.ps1 first." }

# Detected, not hardcoded, so the repo is not tied to one machine.
$account = "$env:USERDOMAIN\$env:USERNAME"
Write-Host "installing for $account"

function New-LogonTask {
    param($Name, $Action, $DelaySeconds, $RunLevel, $Description)

    Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue

    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $account
    # A delay lets the sensor drivers finish initialising before we poke them.
    $trigger.Delay = "PT${DelaySeconds}S"

    $principal = New-ScheduledTaskPrincipal -UserId $account `
                    -LogonType Interactive -RunLevel $RunLevel

    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                    -DontStopIfGoingOnBatteries -StartWhenAvailable `
                    -ExecutionTimeLimit ([TimeSpan]::Zero)

    Register-ScheduledTask -TaskName $Name -Action $Action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description $Description | Out-Null
    Write-Host "  registered: $Name"
}

New-LogonTask -Name 'Taskbar Temp Widget - sensor service' `
    -Action (New-ScheduledTaskAction -Execute $ps51 `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $service)) `
    -DelaySeconds 25 -RunLevel Highest `
    -Description 'Publishes live.txt for the taskbar temperature widget'

New-LogonTask -Name 'Taskbar Temp Widget - display' `
    -Action (New-ScheduledTaskAction -Execute $widget) `
    -DelaySeconds 30 -RunLevel Limited `
    -Description 'CPU/GPU temperature strip on the Windows taskbar'

# Start both now so there is no need to log out and back in.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'sensor-service\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-Process Widget -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# Started through the tasks, not with Start-Process, for two reasons: this
# script runs elevated and a child process would inherit that -- putting the
# display back into the privileged half that splitting the two was meant to
# avoid -- and going through the scheduler proves the tasks themselves work
# rather than just the paths in them.
Start-ScheduledTask -TaskName 'Taskbar Temp Widget - sensor service'
Start-Sleep -Seconds 4
Start-ScheduledTask -TaskName 'Taskbar Temp Widget - display'

Write-Host 'done -- the strip should appear on the taskbar within a few seconds.'
