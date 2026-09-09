# Prints the position of every element on your taskbar, so you can pick where
# the widget should sit.
#
# The widget's horizontal position is two constants in src/Widget.cs
# (LEFT_BOUND / RIGHT_BOUND). Set them to the gap you want to centre in --
# typically the right edge of the Widgets/weather button and the left edge of
# the Start button. Those coordinates differ per machine, taskbar alignment
# and screen width, which is why they are not guessed in code.
#
# Run unelevated. Reads only; changes nothing.

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$AE   = [System.Windows.Automation.AutomationElement]
$cond = New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, 'Shell_TrayWnd')
$bar  = $AE::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)

if (-not $bar) { throw 'Taskbar (Shell_TrayWnd) not found.' }

$r = $bar.Current.BoundingRectangle
Write-Host ("taskbar: x {0} to {1}, y {2}, height {3}" -f `
    [int]$r.X, [int]($r.X + $r.Width), [int]$r.Y, [int]$r.Height)
Write-Host ''

$all = $bar.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                    [System.Windows.Automation.Condition]::TrueCondition)

$rows = foreach ($e in $all) {
    try {
        $b = $e.Current.BoundingRectangle
        if ($b.Width -lt 1 -or $b.Width -gt 2000) { continue }
        if ([string]::IsNullOrEmpty($e.Current.Name)) { continue }
        [pscustomobject]@{
            Name  = $e.Current.Name
            Type  = $e.Current.ControlType.ProgrammaticName -replace 'ControlType\.', ''
            Left  = [int]$b.X
            Right = [int]($b.X + $b.Width)
            Width = [int]$b.Width
        }
    } catch { }
}

$rows | Sort-Object Left | Format-Table -AutoSize

Write-Host 'Look for the Widgets button (its Right edge) and Start (its Left edge).'
Write-Host 'Put those two numbers into LEFT_BOUND / RIGHT_BOUND in src/Widget.cs.'
Write-Host ''
Write-Host 'Note: with a centre-aligned taskbar the Start button drifts left as'
Write-Host 'more apps open, so leave yourself some margin.'
