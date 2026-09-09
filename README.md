# Taskbar Temp Widget

A CPU/GPU temperature strip that sits on the Windows 11 taskbar.

![screenshot](docs/screenshot.png)

Each half shows one component: its current temperature as a hero number, a
sparkline of the last three minutes, a dashed line for fan speed, and the fan
RPM and package wattage. About 14 KB of executable, no installer, no service,
no telemetry.

## Why this exists

Windows 11 removed the deskband API, so nothing can live *inside* the taskbar
any more — that is what killed NetSpeedMonitor and friends. The usual
alternatives (HWiNFO's Sensor Panel, Rainmeter with HWiNFO shared memory) both
need a paid HWiNFO Pro licence. This is a small, free, self-contained
alternative: a borderless click-through window positioned over an empty stretch
of the taskbar.

## Requirements

- Windows 11 (tested on 26200) with a dark taskbar
- [FanControl](https://github.com/Rem0o/FanControl.Releases) installed — the
  sensor service borrows the `LibreHardwareMonitorLib.dll` that ships with it,
  rather than bundling a second copy of the sensor stack
- Nothing else. It builds with the `csc.exe` already present on every Windows
  install, so there is no .NET SDK, NuGet or build system to set up.

## How it works

Two processes, deliberately:

| | runs as | job |
|---|---|---|
| `sensor-service.ps1` | **elevated** | polls the sensors every 2 s, writes `live.txt` |
| `Widget.exe` | normal user | reads `live.txt` every 2 s, draws the strip |

Reading motherboard and CPU sensors needs kernel-level access. Splitting the
two keeps the privileged part to a single PowerShell script that only ever
writes one text file, instead of running the whole GUI as administrator.

`live.txt` is written to a temp name and renamed into place, so the widget can
never read a half-written file. If the newest reading is more than 15 seconds
old the strip dims itself and says `sensors offline` — a monitor that silently
shows frozen numbers is worse than one that admits it has stopped.

## Setup

**1. Find your sensor names.** They differ between motherboards and GPUs. From
an elevated PowerShell:

```powershell
.\tools\list-sensors.ps1
```

Copy the `TYPE|Name` strings you want into the `$Want` table in
`src/sensor-service.ps1`. Keep the type prefix — several sensors share a name
across types (`GPU Core` exists as both `Temperature` and `Load`, `CPU Fan` as
both `Fan` and `Control`), and keying on the name alone lets one overwrite the
other.

**2. Set your fan maxima.** Set `$RpmMaxCpu` and `$RpmMaxGpu` to your fans' top
speed. Fan speed is published as a percentage of maximum so the dashed line has
a stable scale; FanControl's calibration will tell you the numbers.

Rather than editing `src/sensor-service.ps1`, you can copy
`docs/config-local.example.ps1` to `src/config.local.ps1` and put your values
there. That file is gitignored and is dot-sourced after the defaults, so it can
override any setting, extend `$Want` with extra sensors, and point `$CsvLog` at
a CSV log — which keeps machine-specific values out of the tracked script and
survives a `git pull`.

**3. Choose where it sits.** From a normal PowerShell:

```powershell
.\tools\measure-taskbar.ps1
```

Take the right edge of the Widgets button and the left edge of Start, and put
them into `LEFT_BOUND` / `RIGHT_BOUND` in `src/Widget.cs`. The window is
centred in that gap.

**4. Build and install.**

```powershell
.\tools\build.ps1                    # normal PowerShell
.\tools\install.ps1                  # elevated
```

`install.ps1` registers two logon tasks — the service with highest privileges
(so there is no UAC prompt at every logon) and the widget with normal rights —
and starts both immediately.

To remove it:

```powershell
Unregister-ScheduledTask -TaskName 'Taskbar Temp Widget - sensor service' -Confirm:$false
Unregister-ScheduledTask -TaskName 'Taskbar Temp Widget - display' -Confirm:$false
```

## Design notes

These are the decisions that took the longest to get right, kept here so
nobody has to rediscover them.

**One lane, and yes, that makes it a dual-axis chart.** Temperature (°C) and
fan speed (RPM) are different measures, so their crossings and relative
heights genuinely mean nothing — normally the reason not to do this. It was
chosen anyway, with the cost measured first: across ~80 minutes of real
readings the two lines fall within 3 px of each other, reading as a single
band, 4.4 % of the time on the CPU and 20.7 % on the GPU, whose low
temperature and low fan percentage tend to land at the same height. What it
buys is the temperature trace going from 18 px to the chart's full 28 px.

If you would rather have the unambiguous version, give the fan a shorter lane
of its own under a hairline divider and scale each series to its own height:
the change is confined to `Sparkline.OnRender` and `FanY`.

**The temperature scale is fixed at 30–95 °C, not auto-fitted.** An auto-scaled
sparkline lies: a flat line at 90 °C looks identical to a flat line at 45 °C.
With a fixed domain the height of the trace means something, and the CPU is
directly comparable to the GPU. A reference line marks 80 °C.

**No hover layer.** The window has to be click-through or it would block the
taskbar underneath. So the current value is always printed as text and the
reference line gives the scale an anchor — the chart is readable without
interaction.

**Transparency costs ClearType.** WPF disables subpixel antialiasing on layered
windows, which is visible on 9–10 px text. Font weights are one step heavier to
compensate. Going opaque is a tested alternative that does restore ClearType —
set `AllowsTransparency = false` and `Background = Ink.Surface` — at the price
of painting a fixed colour over an acrylic surface that follows the wallpaper.

**Check your taskbar's real colour before trusting contrast.** An acrylic
taskbar shows the wallpaper through it. Measure the pixels where the widget
will actually sit rather than assuming "dark taskbar" — a bright wallpaper can
leave white text on near-white pixels, and sampling elsewhere on the taskbar
measures the icons rather than the background. On the machine this was built
for the strip's background measured `#152537`, dark and stable, so a
transparent background is safe.

**State is never colour alone.** Above 80 °C the value gets an amber glyph,
above 90 °C a red one; the number itself always carries the reading.

**Staying visible needs a nag loop.** The taskbar is topmost too, and within
that band the z-order goes to whoever called `SetWindowPos` last -- Explorer
re-asserts its own on every taskbar event. Without a reminder the strip ends up
behind the taskbar: still there, still reported as visible, but not on screen.
A window cannot be raised *above* the taskbar's band by `SetWindowPos` at all;
that needs the `uiAccess` privilege, which needs a signed binary in a trusted
location. So the widget re-asserts topmost on its own 60 ms timer, which costs
0.06 % of one core. At 2 s the strip visibly blinked out; the burial itself was
later measured at ~72 ms, so the tick period is the upper bound on how long it
is hidden.

**It hides itself for full-screen applications.** Being dependably on top
otherwise means being on top of a full-screen video too, which nobody wants. So
the same 60 ms tick checks whether the foreground window covers the whole of the
monitor the strip is on, and hides the window with `ShowWindow` when it does —
`ShowWindow` rather than WPF's `Hide()`/`Show()`, because coming back must not
activate the window or it would steal focus from the application it was hiding
for.

Comparing against the monitor rather than the work area is what separates
full-screen from merely maximised, and the distinction is finer than it looks:
a maximised window here measures `-8,-8` to `3448,1400` against a 3440x1440
monitor, so it overhangs on three sides and only the bottom edge — where the
taskbar starts — tells the two apart. Checking the strip's monitor rather than
the foreground window's own also means a full-screen video on a second screen
does not blank a strip that is perfectly visible on this one.

The whole check was measured against a build without it, alternating runs:
0.51 % of one core against 0.43 %, where two runs of the *same* build differed
by more than that.

**The Start menu wall — unfixed, and unfixable from here.** *Windows 11 does
not composite ordinary windows over the taskbar's own rectangle while the Start
menu is open.* The strip is simply not drawn for as long as the menu is up, and
no amount of z-order work changes that. It is not a bug in this code.

Four fixes were tried and measured before giving up on that position:

| Attempt | Result |
|---|---|
| Re-assert `HWND_TOPMOST` every 60 ms instead of 250 ms | no change |
| Look for a window covering it | nothing covers it: `IsWindowVisible` true, `DWMWA_CLOAKED` 0, nothing overlapping in front |
| Drop transparency (opaque, unlayered, still top-level) | disappears identically |
| `SetParent` into `Shell_TrayWnd` | window stops rendering entirely, opaque or layered |

The control that settled it: the same window moved 48 px up, just above the
taskbar, stays fully visible for as long as the Start menu is open, while the
taskbar row at that same instant is empty. So the exclusion is the taskbar's
rectangle, not the screen.

So the strip stays on the taskbar and accepts being hidden while the Start menu
is open — moving it 48 px up cures it completely, but then it overlaps the
bottom of every maximised window, which is the worse trade. The one untested
route is `uiAccess`, which needs a signed binary in a trusted location, and
there is no guarantee DWM honours it for this particular exclusion.

A useful side finding, if you ever want to detect the Start menu: while it is
open, `Shell_TrayWnd` drops out of the top-level window enumeration
(`GetTopWindow` + `GW_HWNDNEXT` no longer finds it) while still reporting
itself visible.

## Limitations

- Hardcoded for a 48 px taskbar at 100 % DPI. Other scalings need the sizes
  adjusting.
- The horizontal position is fixed at build time. With a centre-aligned taskbar
  the Start button drifts left as more apps open, so leave margin on the right.
- Single monitor: it places itself on the primary screen's taskbar.
- It is not drawn while the Start menu is open. See **The Start menu wall**.
- It hides itself while a full-screen application is in front, by design. With
  an auto-hidden taskbar a maximised window would also count as full-screen,
  since the work area then covers the whole monitor.
- The `▲` glyph and `°` sign are non-ASCII literals, so `Widget.cs` must keep
  its UTF-8 BOM. `build.ps1` re-adds it before compiling.

## Licence

MIT — see [LICENSE](LICENSE).
