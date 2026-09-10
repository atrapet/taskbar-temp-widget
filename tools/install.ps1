# Registers the two scheduled tasks, then starts both now. Run this ELEVATED
# (right-click > Run with PowerShell as administrator, or from an elevated
# prompt).
#
# Two tasks rather than one, on purpose:
#   - the sensor service needs administrator rights to read the hardware
#   - the widget only reads a text file, so it runs with normal rights
# Registering the service as a scheduled task with highest privileges also
# means no UAC prompt at every logon.
#
# Both tasks are machine-wide rather than tied to the account that runs this
# script, so that every profile on the machine gets the same strip from the
# same checkout:
#
#   - The service runs as SYSTEM at startup. Exactly one instance may exist:
#     a second LibreHardwareMonitorLib fights the first for hardware access,
#     and FanControl is a third consumer of that same library. An at-logon
#     service breaks that twice over -- fast user switching leaves two
#     sessions open and starts it twice, and it dies at every log off, taking
#     the strip down for the next session too.
#
#   - The display task's principal is the Users *group* rather than a named
#     account, so the at-logon trigger fires for whoever signs in and runs in
#     that session with a limited token. One task covers both profiles, and
#     any account added later, with nothing to reinstall.

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

# Printed because the tasks store absolute paths: installing from a stale copy
# of the repo is otherwise invisible until the strip shows the wrong thing.
Write-Host "installing from $repo"

# The checkout must be readable by every account the display task can fire
# for, so a path inside one user's profile will not do. This is a warning
# rather than an error: a single-profile machine is free to keep it there.
if ($repo -like "$env:SystemDrive\Users\*") {
    Write-Warning ("the checkout sits inside a user profile ({0}). " -f $repo +
        'Other profiles cannot read it unless they were granted access, and ' +
        'their widget will start and then find no live.txt.')
}

$serviceTask = 'Taskbar Temp Widget - sensor service'
$displayTask = 'Taskbar Temp Widget - display'

# Tasks are replaced rather than updated: the principal and the trigger both
# changed when the install went machine-wide, and unregistering is the only
# way to be sure no per-user leftovers survive.
foreach ($old in $serviceTask, $displayTask) {
    Unregister-ScheduledTask -TaskName $old -Confirm:$false -ErrorAction SilentlyContinue
}

# --- sensor service: one instance, as SYSTEM, from boot -------------------

$serviceTrigger = New-ScheduledTaskTrigger -AtStartup
# A delay lets the sensor drivers finish initialising before we poke them.
$serviceTrigger.Delay = 'PT30S'

$serviceSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $serviceTask `
    -Action (New-ScheduledTaskAction -Execute $ps51 `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $service)) `
    -Trigger $serviceTrigger `
    -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' `
        -LogonType ServiceAccount -RunLevel Highest) `
    -Settings $serviceSettings `
    -Description 'Publishes live.txt for the taskbar temperature widget (one instance for the whole machine)' | Out-Null
Write-Host "  registered: $serviceTask  (SYSTEM, at startup)"

# --- display: one instance per interactive session ------------------------

$displayTrigger = New-ScheduledTaskTrigger -AtLogOn   # no -User: any account
$displayTrigger.Delay = 'PT30S'

# Parallel, not the default IgnoreNew: with two sessions open at once the
# second user's strip must not be refused because the first user's is running.
$displaySettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances Parallel

# S-1-5-32-545 is BUILTIN\Users by SID rather than by name, which keeps this
# working on a non-English Windows (here the group is called Utilisateurs).
Register-ScheduledTask -TaskName $displayTask `
    -Action (New-ScheduledTaskAction -Execute $widget) `
    -Trigger $displayTrigger `
    -Principal (New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited) `
    -Settings $displaySettings `
    -Description 'CPU/GPU temperature strip on the Windows taskbar (every profile, per session)' | Out-Null
Write-Host "  registered: $displayTask  (any user at logon, per session)"

# --- start both now -------------------------------------------------------

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'sensor-service\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
# Every session's widget, not just this one's -- elevation is what makes
# stopping another user's process possible.
Get-Process Widget -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# Started through the tasks, not with Start-Process, for two reasons: this
# script runs elevated and a child process would inherit that -- putting the
# display back into the privileged half that splitting the two was meant to
# avoid -- and going through the scheduler proves the tasks themselves work
# rather than just the paths in them.
Start-ScheduledTask -TaskName $serviceTask
Start-Sleep -Seconds 6
Start-ScheduledTask -TaskName $displayTask
Start-Sleep -Seconds 4

# --- report what actually happened ---------------------------------------
#
# SYSTEM is a different security context from the account that used to run
# the service, so "registered without error" is not evidence that it can read
# the hardware. Print the proof instead of claiming success.

$live = Join-Path $repo 'src\live.txt'
$log  = Join-Path $repo 'src\service.log'

if (Test-Path $live) {
    $age = [int]((Get-Date) - (Get-Item $live).LastWriteTime).TotalSeconds
    Write-Host ("live.txt: {0} s old" -f $age)
    if ($age -gt 20) {
        Write-Warning 'live.txt is stale -- the service is not publishing. See the log below.'
    }
} else {
    Write-Warning "no live.txt at $live -- the service has not published yet."
}

if (Test-Path $log) { Write-Host ("service.log: " + ((Get-Content $log -Tail 3) -join ' | ')) }

$w = Get-Process Widget -ErrorAction SilentlyContinue
if ($w) {
    Write-Host ("Widget.exe running: " + (($w | ForEach-Object { "pid $($_.Id) session $($_.SessionId)" }) -join ', '))
} else {
    Write-Warning 'Widget.exe is not running.'
}

Write-Host 'done -- the strip should appear on the taskbar within a few seconds.'
