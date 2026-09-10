# Publishes a sensor snapshot for the taskbar widget to read.
#
# Runs ELEVATED: reading motherboard/CPU sensors needs kernel-level access.
# The widget itself runs unelevated and only reads the text file this writes,
# so the privileged surface stays as small as possible.
#
# One instance per machine, not per session: tools\install.ps1 registers it as
# SYSTEM at startup so it outlives log offs and cannot be started twice by two
# open sessions. Two instances would fight over the sensor library, which
# FanControl reads as well.
#
# Requires FanControl (https://github.com/Rem0o/FanControl.Releases) to be
# installed -- this script borrows the LibreHardwareMonitorLib.dll that ships
# with it rather than bundling a second copy of the sensor stack.

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Where FanControl is installed (we only use its bundled sensor library).
$FanControlDir = 'C:\Program Files (x86)\FanControl'

# Fan speed is published as a percentage of maximum, so the widget's dashed
# lane has a stable scale. Set these to YOUR fans' top speed in RPM -- run
# FanControl's calibration to find them, or watch the peak under full load.
$RpmMaxCpu = 1255.0
$RpmMaxGpu = 3000.0

# Optional: append readings to a CSV for later analysis. Empty string = off.
# Rows are "ts,label,type,value" and the header is written if the file is new.
#
# The type column is not decoration. A fan is exposed twice -- as Fan in rpm
# and as Control in percent -- so a consumer reading the label alone cannot
# tell a speed from a command, and would average the two together.
$CsvLog = ''
$CsvEveryNTicks = 3     # 3 x 2 s = one CSV sample every 6 s

# Rename series on the way out, for a consumer that expects its own names.
# Keyed by the role in $Want, after any "@" qualifier is stripped.
$CsvLabels = @{}

$HistoryPoints  = 90   # 90 points x 2 s = 3 minutes of sparkline
$IntervalSeconds = 2

# ---------------------------------------------------------------------------

$outFile = Join-Path $PSScriptRoot 'live.txt'
$tmpFile = Join-Path $PSScriptRoot 'live.tmp'
$logFile = Join-Path $PSScriptRoot 'service.log'

# Sensors of interest, keyed by "TYPE|Name".
#
# The key MUST include the sensor type. Several sensors share a name across
# types -- "GPU Core" exists as both Temperature and Load, "CPU Fan" as both
# Fan and Control. Keying on the name alone lets the load value overwrite the
# temperature, which shows up as a nonsense reading like "GPU 2 deg".
#
# Names come from LibreHardwareMonitor and vary by motherboard. Run
# tools/list-sensors.ps1 to print what your machine exposes.
#
# Roles must be unique, so a sensor tracked under two types needs two roles.
# Suffix the second with "@type" -- "cpuFan" and "cpuFan@Control" -- and the
# CSV writer strips the qualifier, leaving the type column to distinguish them.
$Want = @{
  'Temperature|Core (Tctl/Tdie)'    = 'cpuTemp'   # AMD package temperature
  'Temperature|CPU'                 = 'socket'    # motherboard CPU socket probe
  'Temperature|GPU Core'            = 'gpuTemp'
  'Power|Package'                   = 'cpuW'
  'Power|GPU Package'               = 'gpuW'
  'Fan|CPU Fan'                     = 'cpuFan'
  'Fan|GPU Fan 1'                   = 'gpuFan'
}

# Machine-specific settings live beside this script in config.local.ps1, which
# is untracked: real fan maxima, extra sensors to log, CSV destination. Keeping
# them out of the committed file is what lets one checkout serve one machine
# without the two drifting into separate copies again.
#
# It is dot-sourced here, after the defaults above, so it can override any of
# them and extend $Want in place. See docs/config-local.example.ps1.
$localConfig = Join-Path $PSScriptRoot 'config.local.ps1'
if (Test-Path $localConfig) { . $localConfig }

try {
    # These three ship next to FanControl's copy of the library and are needed
    # before it can open the hardware monitor.
    foreach ($dep in 'System.Security.Principal.Windows.dll',
                     'System.Security.AccessControl.dll',
                     'System.Threading.AccessControl.dll') {
        try { Add-Type -Path (Join-Path $FanControlDir $dep) } catch { }
    }
    Add-Type -Path (Join-Path $FanControlDir 'LibreHardwareMonitorLib.dll')
    Add-Type -Path (Join-Path $FanControlDir 'HidSharp.dll')

    $computer = New-Object LibreHardwareMonitor.Hardware.Computer
    $computer.IsCpuEnabled         = $true
    $computer.IsMotherboardEnabled = $true
    $computer.IsGpuEnabled         = $true
    $computer.IsMemoryEnabled      = $false
    $computer.IsStorageEnabled     = $false
    $computer.IsControllerEnabled  = $false
    $computer.Open()

    "$(Get-Date -Format 's') service started, pid=$PID" | Set-Content $logFile

    $inv     = [System.Globalization.CultureInfo]::InvariantCulture
    $histCpu = New-Object System.Collections.Generic.List[double]
    $histGpu = New-Object System.Collections.Generic.List[double]
    $fanCpu  = New-Object System.Collections.Generic.List[double]
    $fanGpu  = New-Object System.Collections.Generic.List[double]
    $tick    = 0

    while ($true) {
        foreach ($hw in $computer.Hardware) {
            $hw.Update()
            foreach ($sub in $hw.SubHardware) { $sub.Update() }
        }

        $v = @{}
        # $reads keeps the sensor type alongside each value. $v cannot: it is
        # keyed by role, and the role is exactly what drops the type.
        $reads = New-Object System.Collections.Generic.List[object]
        foreach ($hw in $computer.Hardware) {
            foreach ($node in (@($hw) + @($hw.SubHardware))) {
                foreach ($s in $node.Sensors) {
                    if ($null -eq $s.Value) { continue }
                    $key = $Want["$($s.SensorType)|$($s.Name)"]
                    if ($key) {
                        $v[$key] = [double]$s.Value
                        $reads.Add(@{
                            role  = $key
                            type  = [string]$s.SensorType
                            value = [double]$s.Value
                        })
                    }
                }
            }
        }

        if ($v.ContainsKey('cpuTemp')) { $histCpu.Add($v['cpuTemp']) }
        if ($v.ContainsKey('gpuTemp')) { $histGpu.Add($v['gpuTemp']) }
        if ($v.ContainsKey('cpuFan')) {
            $p = 100.0 * $v['cpuFan'] / $RpmMaxCpu
            if ($p -gt 100) { $p = 100 }
            $fanCpu.Add($p)
        }
        if ($v.ContainsKey('gpuFan')) {
            $p = 100.0 * $v['gpuFan'] / $RpmMaxGpu
            if ($p -gt 100) { $p = 100 }
            $fanGpu.Add($p)
        }
        foreach ($list in @($histCpu, $histGpu, $fanCpu, $fanGpu)) {
            while ($list.Count -gt $HistoryPoints) { $list.RemoveAt(0) }
        }

        function Fmt($x) {
            if ($null -eq $x) { '' } else { ([double]$x).ToString('0.#', $inv) }
        }
        function Series($list) {
            ($list | ForEach-Object { $_.ToString('0.#', $inv) }) -join ','
        }

        $lines = @(
            'epoch='    + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            'cpu.temp=' + (Fmt $v['cpuTemp'])
            'cpu.rpm='  + (Fmt $v['cpuFan'])
            'cpu.w='    + (Fmt $v['cpuW'])
            'cpu.hist=' + (Series $histCpu)
            'cpu.fan='  + (Series $fanCpu)
            'gpu.temp=' + (Fmt $v['gpuTemp'])
            'gpu.rpm='  + (Fmt $v['gpuFan'])
            'gpu.w='    + (Fmt $v['gpuW'])
            'gpu.hist=' + (Series $histGpu)
            'gpu.fan='  + (Series $fanGpu)
        )

        # Write-then-rename: the widget must never read a half-written file.
        Set-Content -Path $tmpFile -Value $lines -Encoding ASCII
        Move-Item -Path $tmpFile -Destination $outFile -Force

        $tick++
        if ($CsvLog -and ($tick % $CsvEveryNTicks) -eq 0) {
            if (-not (Test-Path $CsvLog)) {
                Set-Content -Path $CsvLog -Value 'ts,label,type,value' -Encoding UTF8
            }
            $ts = Get-Date -Format 'HH:mm:ss'
            $rows = foreach ($r in $reads) {
                $label = ($r.role -replace '@.*$', '')
                if ($CsvLabels.ContainsKey($label)) { $label = $CsvLabels[$label] }
                "$ts,$label,$($r.type)," + $r.value.ToString('0.#', $inv)
            }
            Add-Content -Path $CsvLog -Value $rows -Encoding UTF8
        }

        Start-Sleep -Seconds $IntervalSeconds
    }
}
catch {
    "$(Get-Date -Format 's') ERROR: $($_.Exception.GetType().Name): $($_.Exception.Message)" |
        Add-Content $logFile
    # Non-zero on the way out, so the scheduled task counts as failed and its
    # restart-on-failure setting applies. Exiting 0 after a crash looks like a
    # clean stop to the scheduler, which then leaves the strip dark until the
    # next boot.
    exit 1
}
