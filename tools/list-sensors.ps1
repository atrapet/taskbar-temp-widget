# Prints every sensor LibreHardwareMonitor can see on this machine, with its
# type, name and current value.
#
# Use it to fill in the $Want table in src/sensor-service.ps1: sensor names
# differ between motherboards and GPUs. Copy the "TYPE|Name" form exactly.
#
# Run ELEVATED -- reading hardware sensors needs kernel-level access.
# Requires FanControl installed (we borrow its bundled sensor library).

$ErrorActionPreference = 'Stop'
$FanControlDir = 'C:\Program Files (x86)\FanControl'

if (-not (Test-Path $FanControlDir)) {
    throw "FanControl not found at $FanControlDir -- edit `$FanControlDir in this script."
}

foreach ($dep in 'System.Security.Principal.Windows.dll',
                 'System.Security.AccessControl.dll',
                 'System.Threading.AccessControl.dll') {
    try { Add-Type -Path (Join-Path $FanControlDir $dep) } catch { }
}
Add-Type -Path (Join-Path $FanControlDir 'LibreHardwareMonitorLib.dll')
Add-Type -Path (Join-Path $FanControlDir 'HidSharp.dll')

$c = New-Object LibreHardwareMonitor.Hardware.Computer
$c.IsCpuEnabled = $true
$c.IsMotherboardEnabled = $true
$c.IsGpuEnabled = $true
$c.Open()
foreach ($hw in $c.Hardware) {
    $hw.Update()
    foreach ($sub in $hw.SubHardware) { $sub.Update() }
}

$rows = foreach ($hw in $c.Hardware) {
    foreach ($node in (@($hw) + @($hw.SubHardware))) {
        foreach ($s in $node.Sensors) {
            [pscustomobject]@{
                Key      = "$($s.SensorType)|$($s.Name)"
                Hardware = $node.Name
                Value    = if ($null -eq $s.Value) { '-' } else { [math]::Round($s.Value, 1) }
            }
        }
    }
}

$c.Close()

$rows | Sort-Object Key | Format-Table -AutoSize

Write-Host ''
Write-Host 'Note the type prefix. Several sensors share a name across types:'
Write-Host '"GPU Core" exists as both Temperature and Load, "CPU Fan" as both'
Write-Host 'Fan and Control. Keying on the name alone lets one overwrite the'
Write-Host 'other, which shows up as a nonsense reading.'
