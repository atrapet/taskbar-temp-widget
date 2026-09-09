// A CPU/GPU temperature strip that sits on the Windows 11 taskbar.
//
// Windows 11 removed the deskband API, so nothing can live *inside* the
// taskbar any more. This is the next best thing: a borderless, click-through,
// always-on-top window positioned over an empty stretch of it.
//
// Design notes worth keeping:
//
//   * One shared lane, two traces that may cross. Temperature (degC) and fan
//     speed (% of max RPM) are unrelated measures on independent y-scales, so
//     an intersection is not itself a data point -- it is read from the shapes
//     (fan ramping while temperature holds, and so on). The solid filled line
//     is temperature, the dashed line is the fan; they share the time axis.
//
//   * The temperature scale is FIXED at 30-95 degC, not auto-fitted. An
//     auto-scaled sparkline lies: a flat line at 90 degC looks identical to a
//     flat line at 45 degC. With a fixed domain the height means something,
//     and CPU is directly comparable to GPU.
//
//   * The background is transparent, which costs ClearType (WPF disables
//     subpixel antialiasing on layered windows). Font weights are bumped one
//     step to compensate. Measure your taskbar's actual colour before
//     assuming text will have contrast against it -- an acrylic taskbar shows
//     the wallpaper through, and a bright wallpaper can leave white text on
//     near-white pixels.
//
//   * There is no hover layer, because the window must be click-through or it
//     would block the taskbar underneath. The current value is therefore
//     always printed as text, and a reference line marks 80 degC, so the chart
//     is readable without interaction.
//
// Builds with csc.exe from the .NET Framework -- no SDK required. See
// tools/build.ps1. Written to C# 5 so that compiler accepts it: no string
// interpolation, no expression-bodied members, no null-conditionals.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace TaskbarTempWidget
{
    // Dark-mode steps of a categorical palette, validated for contrast and
    // colour-vision-deficiency separation against a dark taskbar surface.
    // If you change these, re-check that the two series stay distinguishable.
    static class Ink
    {
        public static readonly Brush Primary   = Solid("#ffffff");
        public static readonly Brush Secondary = Solid("#c3c2b7");
        public static readonly Brush Muted     = Solid("#898781");
        public static readonly Brush Gridline  = Solid("#2c2c2a");
        public static readonly Brush SeriesCpu = Solid("#3987e5");   // blue
        public static readonly Brush SeriesGpu = Solid("#d95926");   // orange
        public static readonly Brush Warning   = Solid("#fab219");
        public static readonly Brush Critical  = Solid("#d03b3b");

        static Brush Solid(string hex)
        {
            SolidColorBrush b = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
            b.Freeze();
            return b;
        }
    }

    // Temperature as a filled line, fan speed as a dashed line, both over the
    // full height and free to cross. Same hue for both, since they describe the
    // same component; the fill and dash pattern tell them apart.
    class Sparkline : FrameworkElement
    {
        const double TEMP_MIN = 30.0;
        const double TEMP_MAX = 95.0;
        const double TEMP_REF = 80.0;   // reference line, the reading anchor

        // Vertical inset so a trace pinned to the top or bottom of its scale,
        // and the end dot, are not clipped by the control edge.
        const double PAD = 4.0;

        double[] temps = new double[0];
        double[] fan = new double[0];

        readonly Brush strokeBrush;
        readonly Brush fillBrush;
        readonly Pen linePen;
        readonly Pen ringPen;
        readonly Pen refPen;
        readonly Pen fanPen;

        public Sparkline(Color c)
        {
            SolidColorBrush s = new SolidColorBrush(c);
            s.Freeze();
            strokeBrush = s;

            LinearGradientBrush g = new LinearGradientBrush();
            g.StartPoint = new Point(0, 0);
            g.EndPoint = new Point(0, 1);
            g.GradientStops.Add(new GradientStop(Color.FromArgb(77, c.R, c.G, c.B), 0));
            g.GradientStops.Add(new GradientStop(Color.FromArgb(8, c.R, c.G, c.B), 1));
            g.Freeze();
            fillBrush = g;

            linePen = new Pen(strokeBrush, 2.0);
            linePen.LineJoin = PenLineJoin.Round;
            linePen.StartLineCap = PenLineCap.Round;
            linePen.EndLineCap = PenLineCap.Round;
            linePen.Freeze();

            // Semi-transparent black rather than a surface colour: with a
            // transparent window there is no opaque surface to imitate, and
            // this still detaches the dot from the line over any background.
            SolidColorBrush ring = new SolidColorBrush(Color.FromArgb(150, 0, 0, 0));
            ring.Freeze();
            ringPen = new Pen(ring, 2.0);
            ringPen.Freeze();

            refPen = new Pen(Ink.Gridline, 1.0);
            refPen.Freeze();

            SolidColorBrush fb = new SolidColorBrush(Color.FromArgb(200, c.R, c.G, c.B));
            fb.Freeze();
            fanPen = new Pen(fb, 1.5);
            fanPen.DashStyle = new DashStyle(new double[] { 3, 2 }, 0);
            fanPen.DashCap = PenLineCap.Flat;
            fanPen.Freeze();
        }

        // temperatures in degC, fanPercent in 0-100
        public void SetData(double[] temperatures, double[] fanPercent)
        {
            temps = (temperatures == null) ? new double[0] : temperatures;
            fan = (fanPercent == null) ? new double[0] : fanPercent;
            InvalidateVisual();
        }

        static double Clamp01(double f)
        {
            if (f < 0) { return 0; }
            if (f > 1) { return 1; }
            return f;
        }

        // Both series map onto the SAME band: y = top at the maximum, y =
        // top + plotH at the minimum. The scales are independent (30-95 degC
        // vs 0-100 % of max RPM), so the traces are free to cross.
        double TempY(double degC, double top, double plotH)
        {
            return top + plotH - Clamp01((degC - TEMP_MIN) / (TEMP_MAX - TEMP_MIN)) * plotH;
        }

        double FanY(double percent, double top, double plotH)
        {
            return top + plotH - Clamp01(percent / 100.0) * plotH;
        }

        protected override void OnRender(DrawingContext dc)
        {
            double w = RenderSize.Width;
            double h = RenderSize.Height;
            if (w <= 0 || h <= 0) { return; }

            double plotWidth = w - 5.0;          // room for the end dot
            double top = PAD;
            double plotH = h - 2 * PAD;
            if (plotH < 6) { top = 0; plotH = h; }   // too short to inset

            double yRef = TempY(TEMP_REF, top, plotH);
            dc.DrawLine(refPen, new Point(0, yRef), new Point(w, yRef));

            // Temperature area + line first, then the fan dashes on top so they
            // stay legible where they run under the translucent fill or cross
            // the temperature trace.
            if (temps.Length >= 2)
            {
                StreamGeometry line = new StreamGeometry();
                StreamGeometry area = new StreamGeometry();
                double dx = plotWidth / (temps.Length - 1);
                double baseY = top + plotH;

                using (StreamGeometryContext cl = line.Open())
                {
                    using (StreamGeometryContext ca = area.Open())
                    {
                        Point first = new Point(0, TempY(temps[0], top, plotH));
                        cl.BeginFigure(first, false, false);
                        ca.BeginFigure(new Point(0, baseY), true, true);
                        ca.LineTo(first, true, false);
                        for (int i = 1; i < temps.Length; i++)
                        {
                            Point p = new Point(i * dx, TempY(temps[i], top, plotH));
                            cl.LineTo(p, true, true);
                            ca.LineTo(p, true, false);
                        }
                        ca.LineTo(new Point(plotWidth, baseY), true, false);
                    }
                }
                line.Freeze();
                area.Freeze();

                dc.DrawGeometry(fillBrush, null, area);
                dc.DrawGeometry(null, linePen, line);
            }

            if (fan.Length >= 2)
            {
                StreamGeometry gf = new StreamGeometry();
                double step = plotWidth / (fan.Length - 1);
                using (StreamGeometryContext ctx = gf.Open())
                {
                    ctx.BeginFigure(new Point(0, FanY(fan[0], top, plotH)), false, false);
                    for (int i = 1; i < fan.Length; i++)
                    {
                        ctx.LineTo(new Point(i * step, FanY(fan[i], top, plotH)), true, false);
                    }
                }
                gf.Freeze();
                dc.DrawGeometry(null, fanPen, gf);
            }

            if (temps.Length >= 2)
            {
                Point last = new Point(plotWidth, TempY(temps[temps.Length - 1], top, plotH));
                dc.DrawEllipse(strokeBrush, ringPen, last, 3.5, 3.5);
            }
        }
    }

    // One block: label, hero value, sparkline, secondary readouts.
    class Block
    {
        public TextBlock Value;
        public TextBlock Glyph;
        public TextBlock Rpm;
        public TextBlock Watt;
        public Sparkline Chart;
        public UIElement Root;

        public Block(string label, Color hue)
        {
            Grid g = new Grid();
            g.ColumnDefinitions.Add(Col(74));
            g.ColumnDefinitions.Add(Col(152));
            g.ColumnDefinitions.Add(Col(62));

            // The text label is what identifies the series, so identity never
            // rests on colour alone.
            StackPanel left = new StackPanel();
            left.VerticalAlignment = VerticalAlignment.Center;

            // Weights are one step heavier than usual: without ClearType the
            // greyscale antialiasing visibly thins the stems.
            TextBlock caption = Text(label, 9.5, Ink.Muted, FontWeights.Bold);
            caption.Margin = new Thickness(0, 0, 0, 1);
            left.Children.Add(caption);

            StackPanel valueRow = new StackPanel();
            valueRow.Orientation = Orientation.Horizontal;
            Value = Text("--", 19, Ink.Primary, FontWeights.Bold);
            Glyph = Text("", 9, Ink.Warning, FontWeights.Bold);
            Glyph.Margin = new Thickness(3, 0, 0, 4);
            Glyph.VerticalAlignment = VerticalAlignment.Bottom;
            valueRow.Children.Add(Value);
            valueRow.Children.Add(Glyph);
            left.Children.Add(valueRow);
            Grid.SetColumn(left, 0);
            g.Children.Add(left);

            Chart = new Sparkline(hue);
            Chart.Height = 28;
            Chart.VerticalAlignment = VerticalAlignment.Center;
            Chart.Margin = new Thickness(0, 0, 6, 0);
            Grid.SetColumn(Chart, 1);
            g.Children.Add(Chart);

            StackPanel right = new StackPanel();
            right.VerticalAlignment = VerticalAlignment.Center;
            Rpm = Text("--", 10, Ink.Secondary, FontWeights.Medium);
            Watt = Text("--", 10, Ink.Secondary, FontWeights.Medium);
            // Tabular figures because these two stack in a column and should
            // not jitter sideways as digits change.
            Typography.SetNumeralAlignment(Rpm, FontNumeralAlignment.Tabular);
            Typography.SetNumeralAlignment(Watt, FontNumeralAlignment.Tabular);
            Watt.Margin = new Thickness(0, 2, 0, 0);
            right.Children.Add(Rpm);
            right.Children.Add(Watt);
            Grid.SetColumn(right, 2);
            g.Children.Add(right);

            Root = g;
        }

        static ColumnDefinition Col(double w)
        {
            ColumnDefinition c = new ColumnDefinition();
            c.Width = new GridLength(w);
            return c;
        }

        static TextBlock Text(string s, double size, Brush brush, FontWeight weight)
        {
            TextBlock t = new TextBlock();
            t.Text = s;
            t.FontFamily = new FontFamily("Segoe UI");
            t.FontSize = size;
            t.Foreground = brush;
            t.FontWeight = weight;
            return t;
        }
    }

    class MainWindow : Window
    {
        // ------------------------------------------------------------------
        // Position. Run tools/measure-taskbar.ps1 to get these for YOUR
        // taskbar: the right edge of the Widgets button and the left edge of
        // Start. The window is centred in that gap.
        //
        // With a centre-aligned taskbar the Start button drifts left as more
        // apps open, so leave margin on the right.
        // ------------------------------------------------------------------
        const double LEFT_BOUND = 158.0;
        const double RIGHT_BOUND = 1410.0;

        const double WIDTH = 660.0;
        const double HEIGHT = 48.0;   // Windows 11 taskbar height at 100% DPI

        // Above this the value turns amber, above the second it turns red.
        // Both also show a glyph, so state is never colour alone.
        const double WARN_C = 80.0;
        const double CRIT_C = 90.0;

        // Treat readings older than this as stale. A monitor that silently
        // shows frozen numbers is worse than one that admits it is offline.
        const int STALE_SECONDS = 15;

        const int GWL_EXSTYLE = -20;
        const int WS_EX_TRANSPARENT = 0x20;
        const int WS_EX_NOACTIVATE = 0x8000000;
        const int WS_EX_TOOLWINDOW = 0x80;

        [DllImport("user32.dll")]
        static extern int GetWindowLong(IntPtr h, int index);

        [DllImport("user32.dll")]
        static extern int SetWindowLong(IntPtr h, int index, int value);

        [DllImport("user32.dll")]
        static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);

        static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        const uint SWP_NOSIZE = 0x1;
        const uint SWP_NOMOVE = 0x2;
        const uint SWP_NOACTIVATE = 0x10;

        // The taskbar is topmost too. Within that band the z-order goes to
        // whoever called SetWindowPos last, and Explorer re-asserts its own on
        // every taskbar event -- opening the Start menu is enough. Without this
        // reminder the strip ends up under the taskbar: still there, still
        // reported as visible, but not on screen.
        //
        // Note that a window cannot be raised *above* the taskbar's band by
        // SetWindowPos alone; that needs the uiAccess privilege, which in turn
        // needs a signed binary in a trusted location. Re-asserting topmost is
        // what keeps it drawn, and it has to be frequent: at 2 s the strip
        // visibly blinked out when Start was pressed, so it runs on its own
        // 250 ms timer. A SetWindowPos with no move and no resize is close to
        // free.
        void KeepOnTop()
        {
            IntPtr h = new WindowInteropHelper(this).Handle;
            if (h == IntPtr.Zero) { return; }
            SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }

        Block cpu;
        Block gpu;
        Border frame;
        TextBlock offlineLabel;
        readonly string dataFile;

        public MainWindow()
        {
            string dir = Path.GetDirectoryName(
                System.Reflection.Assembly.GetExecutingAssembly().Location);
            dataFile = Path.Combine(dir, "live.txt");

            WindowStyle = WindowStyle.None;
            ResizeMode = ResizeMode.NoResize;
            AllowsTransparency = true;
            ShowInTaskbar = false;
            Topmost = true;
            Background = Brushes.Transparent;
            TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);

            Width = WIDTH;
            Height = HEIGHT;

            double screenH = SystemParameters.PrimaryScreenHeight;
            double workH = SystemParameters.WorkArea.Height;
            Top = (screenH > workH) ? workH : (screenH - HEIGHT);

            double centre = (LEFT_BOUND + RIGHT_BOUND) / 2.0;
            double x = centre - WIDTH / 2.0;
            if (x < LEFT_BOUND) { x = LEFT_BOUND + 8; }
            Left = x;

            Grid row = new Grid();
            row.ColumnDefinitions.Add(AutoCol());
            row.ColumnDefinitions.Add(FixedCol(1));
            row.ColumnDefinitions.Add(AutoCol());

            cpu = new Block("CPU", ((SolidColorBrush)Ink.SeriesCpu).Color);
            gpu = new Block("GPU", ((SolidColorBrush)Ink.SeriesGpu).Color);

            Border divider = new Border();
            divider.Background = Ink.Gridline;
            divider.Margin = new Thickness(8, 10, 8, 10);

            Grid.SetColumn(cpu.Root, 0);
            Grid.SetColumn(divider, 1);
            Grid.SetColumn(gpu.Root, 2);
            row.Children.Add(cpu.Root);
            row.Children.Add(divider);
            row.Children.Add(gpu.Root);

            offlineLabel = new TextBlock();
            offlineLabel.Text = "sensors offline";
            offlineLabel.FontFamily = new FontFamily("Segoe UI");
            offlineLabel.FontSize = 10;
            offlineLabel.Foreground = Ink.Muted;
            offlineLabel.HorizontalAlignment = HorizontalAlignment.Right;
            offlineLabel.VerticalAlignment = VerticalAlignment.Center;
            offlineLabel.Visibility = Visibility.Collapsed;

            Grid stack = new Grid();
            stack.Children.Add(row);
            stack.Children.Add(offlineLabel);

            frame = new Border();
            frame.Background = Brushes.Transparent;
            frame.BorderThickness = new Thickness(0);
            frame.Padding = new Thickness(4, 0, 12, 0);
            frame.Child = stack;
            Content = frame;

            SourceInitialized += new EventHandler(OnSourceInitialized);

            DispatcherTimer timer = new DispatcherTimer();
            timer.Interval = TimeSpan.FromSeconds(2);
            timer.Tick += new EventHandler(OnTick);
            timer.Start();

            DispatcherTimer topTimer = new DispatcherTimer();
            topTimer.Interval = TimeSpan.FromMilliseconds(250);
            topTimer.Tick += new EventHandler(OnTopTick);
            topTimer.Start();

            Refresh();
        }

        static ColumnDefinition AutoCol()
        {
            ColumnDefinition c = new ColumnDefinition();
            c.Width = GridLength.Auto;
            return c;
        }

        static ColumnDefinition FixedCol(double w)
        {
            ColumnDefinition c = new ColumnDefinition();
            c.Width = new GridLength(w);
            return c;
        }

        void OnSourceInitialized(object sender, EventArgs e)
        {
            IntPtr h = new WindowInteropHelper(this).Handle;
            int ex = GetWindowLong(h, GWL_EXSTYLE);
            // Click-through, never activated, out of Alt-Tab: the strip must
            // not swallow taskbar clicks or steal focus.
            SetWindowLong(h, GWL_EXSTYLE,
                ex | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW);
            KeepOnTop();
        }

        void OnTick(object sender, EventArgs e)
        {
            Refresh();
        }

        void OnTopTick(object sender, EventArgs e)
        {
            KeepOnTop();
        }

        void Refresh()
        {
            try
            {
                if (!File.Exists(dataFile)) { GoOffline(); return; }

                string[] lines = File.ReadAllLines(dataFile);
                Dictionary<string, string> d = new Dictionary<string, string>();
                for (int i = 0; i < lines.Length; i++)
                {
                    int eq = lines[i].IndexOf('=');
                    if (eq > 0)
                    {
                        d[lines[i].Substring(0, eq)] = lines[i].Substring(eq + 1);
                    }
                }

                long epoch;
                if (!d.ContainsKey("epoch") || !long.TryParse(d["epoch"], out epoch))
                {
                    GoOffline();
                    return;
                }
                if (DateTimeOffset.UtcNow.ToUnixTimeSeconds() - epoch > STALE_SECONDS)
                {
                    GoOffline();
                    return;
                }

                offlineLabel.Visibility = Visibility.Collapsed;
                frame.Opacity = 1.0;
                Apply(cpu, d, "cpu");
                Apply(gpu, d, "gpu");
            }
            catch
            {
                GoOffline();
            }
        }

        void GoOffline()
        {
            frame.Opacity = 0.45;
            offlineLabel.Visibility = Visibility.Visible;
            cpu.Value.Text = "--";
            gpu.Value.Text = "--";
            cpu.Glyph.Text = "";
            gpu.Glyph.Text = "";
            cpu.Rpm.Text = "";
            cpu.Watt.Text = "";
            gpu.Rpm.Text = "";
            gpu.Watt.Text = "";
            cpu.Chart.SetData(null, null);
            gpu.Chart.SetData(null, null);
        }

        static void Apply(Block b, Dictionary<string, string> d, string prefix)
        {
            CultureInfo inv = CultureInfo.InvariantCulture;

            double temp;
            if (ReadNum(d, prefix + ".temp", out temp))
            {
                b.Value.Text = Math.Round(temp).ToString(inv) + "°";
                if (temp >= CRIT_C)
                {
                    b.Value.Foreground = Ink.Critical;
                    b.Glyph.Foreground = Ink.Critical;
                    b.Glyph.Text = "▲";
                }
                else if (temp >= WARN_C)
                {
                    b.Value.Foreground = Ink.Primary;
                    b.Glyph.Foreground = Ink.Warning;
                    b.Glyph.Text = "▲";
                }
                else
                {
                    b.Value.Foreground = Ink.Primary;
                    b.Glyph.Text = "";
                }
            }

            double rpm;
            if (ReadNum(d, prefix + ".rpm", out rpm))
            {
                b.Rpm.Text = (rpm < 1) ? "idle" : (Math.Round(rpm).ToString(inv) + " rpm");
            }

            double watts;
            if (ReadNum(d, prefix + ".w", out watts))
            {
                b.Watt.Text = Math.Round(watts).ToString(inv) + " W";
            }

            b.Chart.SetData(ReadSeries(d, prefix + ".hist"), ReadSeries(d, prefix + ".fan"));
        }

        static double[] ReadSeries(Dictionary<string, string> d, string key)
        {
            string raw;
            if (!d.TryGetValue(key, out raw) || raw.Length == 0) { return new double[0]; }
            CultureInfo inv = CultureInfo.InvariantCulture;
            string[] parts = raw.Split(',');
            double[] buf = new double[parts.Length];
            int n = 0;
            for (int i = 0; i < parts.Length; i++)
            {
                double v;
                if (double.TryParse(parts[i], NumberStyles.Float, inv, out v))
                {
                    buf[n] = v;
                    n++;
                }
            }
            double[] result = new double[n];
            Array.Copy(buf, result, n);
            return result;
        }

        static bool ReadNum(Dictionary<string, string> d, string key, out double value)
        {
            value = 0;
            string raw;
            if (!d.TryGetValue(key, out raw) || raw.Length == 0) { return false; }
            return double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out value);
        }
    }

    public class Program
    {
        [STAThread]
        public static void Main()
        {
            Application app = new Application();
            app.ShutdownMode = ShutdownMode.OnLastWindowClose;
            MainWindow w = new MainWindow();
            w.Show();
            app.Run();
        }
    }
}
