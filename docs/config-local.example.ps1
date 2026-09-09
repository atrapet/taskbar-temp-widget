# Example src/config.local.ps1 -- copy it next to sensor-service.ps1 to adapt
# the service to your machine without editing the tracked script.
#
# It is dot-sourced after the defaults, so anything set here wins, and $Want
# can be extended in place. Everything is optional; delete what you do not
# need. Run tools/list-sensors.ps1 first to get your real sensor names.

# Your fans' top speed in RPM, from FanControl's calibration. The widget's
# dashed lane is a percentage of these, so a wrong value silently rescales it.
$RpmMaxCpu = 1255.0
$RpmMaxGpu = 3000.0

# Log every sensor below to a CSV for later analysis.
$CsvLog = 'C:\path\to\watch.csv'

# Rename series for a consumer that expects its own names.
$CsvLabels = @{
  cpuTemp = 'tctl'
  gpuTemp = 'gpu'
}

# Extra sensors, logged to the CSV but not shown by the widget. Roles must be
# unique, so a sensor tracked as both Fan and Control needs the "@" qualifier.
$Want['Temperature|VRM MOS']  = 'vrm'
$Want['Control|CPU Fan']      = 'cpuFan@Control'
