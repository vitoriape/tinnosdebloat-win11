using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Globalization;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: AssemblyTitle("TinnosDebloat-Win11")]
[assembly: AssemblyDescription("Windows 11 provisioning and Teams removal")]
[assembly: AssemblyVersion("2.8.0.0")]

namespace TinnosDebloat
{
    public static class Payload
    {
        public static readonly string[] Files = { "Invoke-Provisioning.ps1", "Invoke-UserCleanup.ps1", "Provisioning.psm1", "Check-OfficeActivation.ps1", "config.example.json", "error-codes.json", "debloat-catalog.json" };
        public static void Validate()
        {
            foreach (string file in Files)
                using (Stream data = Assembly.GetExecutingAssembly().GetManifestResourceStream("Payload." + file))
                    if (data == null || data.Length == 0) throw new InvalidDataException("Missing embedded file: " + file);
        }
        public static string Quote(string value)
        {
            StringBuilder result = new StringBuilder("\""); int slashes = 0;
            foreach (char c in value)
            {
                if (c == '\\') { slashes++; continue; }
                result.Append('\\', c == '"' ? slashes * 2 + 1 : slashes);
                result.Append(c); slashes = 0;
            }
            result.Append('\\', slashes * 2); return result.Append('"').ToString();
        }
        public static string Extract()
        {
            Validate();
            string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "TinnosDebloat-Win11", "Runs");
            for (DirectoryInfo parent = new DirectoryInfo(root); parent != null; parent = parent.Parent)
                if (parent.Exists && (parent.Attributes & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("Redirected application directory: " + parent.FullName);
            DirectorySecurity acl = new DirectorySecurity(); acl.SetAccessRuleProtection(true, false);
            acl.SetOwner(new SecurityIdentifier("S-1-5-32-544"));
            foreach (string sid in new string[] { "S-1-5-18", "S-1-5-32-544" })
                acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid), FileSystemRights.FullControl,
                    InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier("S-1-5-32-545"), FileSystemRights.ReadAndExecute,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            Directory.CreateDirectory(root, acl); Directory.SetAccessControl(root, acl);
            string directory = Path.Combine(root, DateTime.UtcNow.ToString("yyyyMMddTHHmmss") + "-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory, acl);
            foreach (string file in Files)
                using (Stream data = Assembly.GetExecutingAssembly().GetManifestResourceStream("Payload." + file))
                using (FileStream destination = new FileStream(Path.Combine(directory, file), FileMode.CreateNew)) data.CopyTo(destination);
            return directory;
        }
        public static ProcessStartInfo Command(string directory, string config, string mode, string output)
        {
            if (mode != "Audit" && mode != "Plan" && mode != "Deploy") throw new ArgumentException("Unknown run mode.");
            return new ProcessStartInfo {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"),
                // Per-process setting for this packaged app. GPO MachinePolicy/UserPolicy still win.
                Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(Path.Combine(directory, "Invoke-Provisioning.ps1"))
                    + " -ConfigPath " + Quote(Path.GetFullPath(config)) + " -Mode " + mode + " -OutputDirectory " + Quote(Path.GetFullPath(output)),
                WorkingDirectory = directory, UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = new UTF8Encoding(false), StandardErrorEncoding = new UTF8Encoding(false)
            };
        }
    }

    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            if (args.Length == 0) return Startup.RunGui(delegate { return Ui.Create(); });
            CultureInfo english = CultureInfo.GetCultureInfo("en-US");
            CultureInfo.DefaultThreadCurrentCulture = english; CultureInfo.DefaultThreadCurrentUICulture = english;
            Thread.CurrentThread.CurrentCulture = english; Thread.CurrentThread.CurrentUICulture = english;
            try { Console.OutputEncoding = new UTF8Encoding(false); } catch (IOException) { }
            return CommandLine(args);
        }
        private static int CommandLine(string[] args)
        {
            string directory = null;
            try
            {
                string config = null, mode = "Audit", output = null;
                for (int i = 0; i < args.Length; i += 2)
                {
                    if (i + 1 >= args.Length) throw new ArgumentException("Expected --mode Audit|Plan|Deploy [--config file] [--output folder].");
                    switch (args[i]) {
                        case "--mode": mode = args[i + 1]; break;
                        case "--config": config = Path.GetFullPath(args[i + 1]); break;
                        case "--output": output = Path.GetFullPath(args[i + 1]); break;
                        default: throw new ArgumentException("Unknown option: " + args[i]);
                    }
                }
                directory = Payload.Extract();
                if (config == null) config = Path.Combine(directory, "config.example.json");
                if (output == null) output = Path.Combine(directory, "Work");
                using (Process process = new Process { StartInfo = Payload.Command(directory, config, mode, output) })
                {
                    object sync = new object();
                    DataReceivedEventHandler append = delegate(object sender, DataReceivedEventArgs e) {
                        if (e.Data != null) lock (sync) { Console.WriteLine(e.Data); }
                    };
                    process.OutputDataReceived += append; process.ErrorDataReceived += append;
                    process.Start(); process.BeginOutputReadLine(); process.BeginErrorReadLine(); process.WaitForExit();
                    return process.ExitCode;
                }
            }
            catch (Exception error) {
                Console.Error.WriteLine(ResultChannel.ErrorText("TNO-901", error.Message));
                return 1;
            }
        }
    }

    public static class ResultChannel
    {
        public const string Prefix = "TINNOS_RESULT:";
        public static string Decode(string line)
        {
            if (!line.StartsWith(Prefix, StringComparison.Ordinal)) throw new InvalidDataException("Missing result prefix.");
            return Encoding.UTF8.GetString(Convert.FromBase64String(line.Substring(Prefix.Length)));
        }
        public static JavaScriptSerializer Serializer() { return new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 100 }; }
        public static string ErrorText(string code, string message)
        {
            using (Stream data = Assembly.GetExecutingAssembly().GetManifestResourceStream("Payload.error-codes.json"))
            using (StreamReader reader = new StreamReader(data))
            {
                Dictionary<string, object> catalog = Serializer().DeserializeObject(reader.ReadToEnd()) as Dictionary<string, object>;
                Dictionary<string, object> entry = catalog[code] as Dictionary<string, object>;
                return "[" + code + "] " + entry["Title"] + Environment.NewLine + message + Environment.NewLine + "Next step: " + entry["Action"];
            }
        }
    }

    public static class Startup
    {
        public static int RunGui(Func<Form> createForm) { return RunGui(createForm, ShowFailure); }
        public static int RunGui(Func<Form> createForm, Action<Exception> failure)
        {
            try {
                // Explorer-launched WinForms applications have no console handle.
                // Console.OutputEncoding must never be set on this startup path.
                CultureInfo english = CultureInfo.GetCultureInfo("en-US");
                CultureInfo.DefaultThreadCurrentCulture = english; CultureInfo.DefaultThreadCurrentUICulture = english;
                Thread.CurrentThread.CurrentCulture = english; Thread.CurrentThread.CurrentUICulture = english;
                Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
                Application.SetUnhandledExceptionMode(UnhandledExceptionMode.ThrowException);
                using (Form form = createForm()) { Application.Run(form); }
                return 0;
            } catch (Exception error) { failure(error); return 1; }
        }
        private static void ShowFailure(Exception error)
        {
            // Hard-coded fallback also works if embedded resources could not load.
            MessageBox.Show("[TNO-905] The application could not display its window." + Environment.NewLine
                + error.Message + Environment.NewLine + Environment.NewLine
                + "Use the latest complete executable. Include this message when reporting the problem.",
                "TinnosDebloat-Win11 - Startup error", MessageBoxButtons.OK, MessageBoxIcon.Error,
                MessageBoxDefaultButton.Button1, MessageBoxOptions.DefaultDesktopOnly);
        }
    }

    public static class Ui
    {
        public static Form Create() { return new MainForm(); }
    }

    internal sealed class ChoiceList : CheckedListBox
    {
        private readonly ToolTip hint = new ToolTip();
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
        public int RowHeight { get { return Math.Max(36, Font.Height + 16); } }
        public ChoiceList()
        {
            Dock = DockStyle.Fill; CheckOnClick = true; IntegralHeight = false;
            BorderStyle = BorderStyle.None; BackColor = Color.FromArgb(25, 31, 36);
            ForeColor = Color.FromArgb(225, 230, 233); Font = new Font("Segoe UI", 10.5f);
            MouseMove += delegate(object sender, MouseEventArgs e) {
                int index = IndexFromPoint(e.Location); string label = index < 0 ? "" : Items[index].ToString();
                if (hint.GetToolTip(this) != label) hint.SetToolTip(this, label);
            };
        }
        protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); SendMessage(Handle, 0x1a0, IntPtr.Zero, new IntPtr(RowHeight)); }
        protected override void OnDrawItem(DrawItemEventArgs e)
        {
            if (e.Index < 0 || e.Index >= Items.Count) return;
            using (SolidBrush fill = new SolidBrush((e.State & DrawItemState.Selected) != 0 ? Color.FromArgb(34, 43, 49) : BackColor)) e.Graphics.FillRectangle(fill, e.Bounds);
            Rectangle box = new Rectangle(e.Bounds.X + 7, e.Bounds.Y + (e.Bounds.Height - 17) / 2, 17, 17);
            e.Graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            using (System.Drawing.Drawing2D.GraphicsPath shape = Visuals.Rounded(box, 4)) {
                using (SolidBrush fill = new SolidBrush(GetItemChecked(e.Index) ? Color.FromArgb(244, 195, 64) : Color.FromArgb(34, 42, 48))) e.Graphics.FillPath(fill, shape);
                using (Pen outline = new Pen(GetItemChecked(e.Index) ? Color.FromArgb(244, 195, 64) : Color.FromArgb(83, 96, 104))) e.Graphics.DrawPath(outline, shape);
            }
            if (GetItemChecked(e.Index)) using (Pen tick = new Pen(Color.FromArgb(20, 26, 30), 2))
                e.Graphics.DrawLines(tick, new Point[] { new Point(box.X + 4, box.Y + 8), new Point(box.X + 7, box.Y + 11), new Point(box.X + 13, box.Y + 5) });
            TextRenderer.DrawText(e.Graphics, Items[e.Index].ToString(), Font,
                new Rectangle(e.Bounds.X + 36, e.Bounds.Y, Math.Max(1, e.Bounds.Width - 43), e.Bounds.Height), Enabled ? ForeColor : Color.Gray,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);
        }
        protected override void Dispose(bool disposing) { if (disposing) hint.Dispose(); base.Dispose(disposing); }
    }
    internal static class Visuals
    {
        public static System.Drawing.Drawing2D.GraphicsPath Rounded(Rectangle bounds, int radius)
        {
            System.Drawing.Drawing2D.GraphicsPath path = new System.Drawing.Drawing2D.GraphicsPath();
            int d = Math.Max(2, Math.Min(radius * 2, Math.Min(bounds.Width, bounds.Height)));
            path.AddArc(bounds.X, bounds.Y, d, d, 180, 90); path.AddArc(bounds.Right - d, bounds.Y, d, d, 270, 90);
            path.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90); path.AddArc(bounds.X, bounds.Bottom - d, d, d, 90, 90); path.CloseFigure(); return path;
        }
    }
    internal sealed class SurfaceCard : Panel
    {
        public SurfaceCard() { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true); BackColor = Color.FromArgb(16, 21, 25); Padding = new Padding(18); }
        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e); e.Graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            using (System.Drawing.Drawing2D.GraphicsPath path = Visuals.Rounded(new Rectangle(0, 0, Width - 1, Height - 1), 15)) {
                using (SolidBrush fill = new SolidBrush(Color.FromArgb(25, 31, 36))) e.Graphics.FillPath(fill, path);
                using (Pen edge = new Pen(Color.FromArgb(43, 52, 59))) e.Graphics.DrawPath(edge, path);
            }
        }
    }
    internal sealed class CleanupSection : Panel
    {
        public readonly ChoiceList List = new ChoiceList();
        public readonly Button Toggle;
        private readonly string title;
        public bool Expanded { get; private set; }
        public CleanupSection(string name, string label, bool expanded)
        {
            Name = "group" + name; title = label; BackColor = Color.FromArgb(25, 31, 36); Margin = new Padding(0, 0, 0, 9);
            Toggle = new Button { Name = "toggle" + name, TextAlign = ContentAlignment.MiddleLeft, FlatStyle = FlatStyle.Flat, Dock = DockStyle.Top,
                Height = 42, BackColor = Color.FromArgb(34, 42, 48), ForeColor = Color.FromArgb(225, 230, 233), Font = new Font("Segoe UI Semibold", 10) };
            Toggle.Cursor = Cursors.Hand; Toggle.FlatAppearance.BorderSize = 0; Toggle.FlatAppearance.MouseOverBackColor = Color.FromArgb(43, 53, 61);
            List.Name = "cleanup" + name; List.Dock = DockStyle.Fill;
            Controls.Add(List); Controls.Add(Toggle); Expanded = expanded;
            Toggle.Click += delegate { SetExpanded(!Expanded); };
        }
        public void SetExpanded(bool expanded)
        {
            Expanded = expanded; List.Visible = expanded;
            Toggle.Text = (expanded ? "\u2304  " : "\u203a  ") + title + "   " + List.Items.Count;
            Toggle.AccessibleName = title + (expanded ? " expanded" : " collapsed");
            Height = 42 + (expanded ? Math.Min(248, List.Items.Count * List.RowHeight + 4) : 0);
        }
    }

    internal sealed class DesktopPreview : Control
    {
        private Image wallpaper;
        private string imagePath = "";
        private string[] programs = new string[0];
        public string WallpaperPath { get { return imagePath; } }
        public string[] Programs { get { return (string[])programs.Clone(); } }
        public bool Moss, DesktopIcons, Translucent;
        public DesktopPreview()
        {
            Name = "desktopPreview"; Dock = DockStyle.Fill; BackColor = Color.FromArgb(25, 31, 36);
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        }
        public void UpdateDesktop(string path, string[] selectedPrograms)
        {
            if (path != imagePath) {
                Image next = null;
                if (path != "" && File.Exists(path)) using (Image source = Image.FromFile(path)) next = new Bitmap(source);
                if (wallpaper != null) wallpaper.Dispose(); wallpaper = next; imagePath = path;
            }
            programs = selectedPrograms;
            AccessibleDescription = "Desktop preview. Wallpaper: " + (path == "" ? "Default preview" : Path.GetFileName(path)) + ". Taskbar apps: " + string.Join(", ", programs);
            Invalidate();
        }
        private static void AppIcon(Graphics g, string app, Rectangle rect)
        {
            if (app == "Google Chrome") {
                using (SolidBrush red = new SolidBrush(Color.FromArgb(235, 80, 65))) g.FillPie(red, rect, 210, 120);
                using (SolidBrush yellow = new SolidBrush(Color.FromArgb(247, 199, 65))) g.FillPie(yellow, rect, 330, 120);
                using (SolidBrush green = new SolidBrush(Color.FromArgb(68, 174, 111))) g.FillPie(green, rect, 90, 120);
                Rectangle center = Rectangle.Inflate(rect, -rect.Width / 3, -rect.Height / 3);
                using (SolidBrush blue = new SolidBrush(Color.FromArgb(70, 145, 227))) g.FillEllipse(blue, center);
            } else if (app == "Google Drive") {
                Point top = new Point(rect.X + rect.Width / 2, rect.Y), left = new Point(rect.X, rect.Bottom), right = new Point(rect.Right, rect.Bottom);
                using (Pen pen = new Pen(Color.FromArgb(77, 179, 117), Math.Max(3, rect.Width / 4))) g.DrawLine(pen, top, left);
                using (Pen pen = new Pen(Color.FromArgb(246, 199, 72), Math.Max(3, rect.Width / 4))) g.DrawLine(pen, top, right);
                using (Pen pen = new Pen(Color.FromArgb(72, 142, 233), Math.Max(3, rect.Width / 4))) g.DrawLine(pen, left, right);
            } else {
                Color color = app == "Microsoft 365" ? Color.FromArgb(236, 108, 63) : Color.FromArgb(112, 180, 204);
                using (SolidBrush fill = new SolidBrush(color)) using (System.Drawing.Drawing2D.GraphicsPath shape = Visuals.Rounded(rect, 5)) g.FillPath(fill, shape);
                using (Font font = new Font("Segoe UI", Math.Max(7, rect.Height * .48f), FontStyle.Bold))
                    TextRenderer.DrawText(g, app == "Microsoft 365" ? "O" : "T", font, rect, Color.White, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            }
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e); Graphics g = e.Graphics; g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            int width = Math.Max(20, ClientSize.Width - 4), height = Math.Max(90, Math.Min((int)(width * .64), ClientSize.Height - 100 - programs.Length * 42));
            Rectangle screen = new Rectangle(2, 14, width - 4, height);
            using (System.Drawing.Drawing2D.GraphicsPath shape = Visuals.Rounded(screen, 11)) {
                System.Drawing.Drawing2D.GraphicsState state = g.Save(); g.SetClip(shape);
                if (wallpaper != null) {
                    float scale = Math.Max((float)screen.Width / wallpaper.Width, (float)screen.Height / wallpaper.Height);
                    float w = wallpaper.Width * scale, h = wallpaper.Height * scale;
                    g.DrawImage(wallpaper, screen.X + (screen.Width - w) / 2, screen.Y + (screen.Height - h) / 2, w, h);
                } else {
                    using (System.Drawing.Drawing2D.LinearGradientBrush sky = new System.Drawing.Drawing2D.LinearGradientBrush(screen,
                        Moss ? Color.FromArgb(72, 104, 96) : Color.FromArgb(28, 61, 77), Color.FromArgb(13, 30, 37), 65f)) g.FillRectangle(sky, screen);
                    using (SolidBrush hill = new SolidBrush(Color.FromArgb(55, 111, 108))) g.FillEllipse(hill, screen.X - width / 2, screen.Y + height / 3, width + width / 2, height * 2);
                    using (SolidBrush hill = new SolidBrush(Color.FromArgb(30, 73, 77))) g.FillEllipse(hill, screen.X + width / 3, screen.Y + height / 2, width, height);
                }
                if (DesktopIcons) using (SolidBrush white = new SolidBrush(Color.FromArgb(205, 222, 230))) {
                    g.FillRectangle(white, screen.X + 13, screen.Y + 15, 13, 17); g.FillRectangle(white, screen.X + 13, screen.Y + 51, 13, 17);
                }
                Rectangle taskbar = new Rectangle(screen.X, screen.Bottom - 36, screen.Width, 36);
                using (SolidBrush fill = new SolidBrush(Color.FromArgb(Translucent ? 100 : 238, 19, 27, 34))) g.FillRectangle(fill, taskbar);
                int count = 1 + programs.Length, gap = 30, x = screen.X + (screen.Width - count * gap) / 2;
                using (SolidBrush win = new SolidBrush(Color.FromArgb(98, 184, 235))) {
                    g.FillRectangle(win, x, taskbar.Y + 10, 7, 7); g.FillRectangle(win, x + 9, taskbar.Y + 10, 7, 7);
                    g.FillRectangle(win, x, taskbar.Y + 19, 7, 7); g.FillRectangle(win, x + 9, taskbar.Y + 19, 7, 7);
                }
                for (int i = 0; i < programs.Length; i++) AppIcon(g, programs[i], new Rectangle(x + (i + 1) * gap, taskbar.Y + 10, 17, 17));
                g.Restore(state);
                using (Pen edge = new Pen(Color.FromArgb(67, 82, 91))) g.DrawPath(edge, shape);
            }
            int y = screen.Bottom + 28;
            using (Font title = new Font("Segoe UI Semibold", 9)) TextRenderer.DrawText(g, "ON YOUR TASKBAR", title, new Point(2, y), Color.FromArgb(139, 155, 166));
            y += 32;
            if (programs.Length == 0) using (Font font = new Font("Segoe UI", 10)) TextRenderer.DrawText(g, "Choose your gear to build the preview.", font, new Rectangle(2, y, width, 50), Color.Silver, TextFormatFlags.WordBreak);
            foreach (string program in programs) {
                AppIcon(g, program, new Rectangle(5, y + 2, 23, 23));
                using (Font font = new Font("Segoe UI", 10)) TextRenderer.DrawText(g, program, font, new Rectangle(42, y, width - 44, 30), Color.FromArgb(220, 228, 232), TextFormatFlags.Left | TextFormatFlags.VerticalCenter);
                y += 42;
            }
        }
        protected override void Dispose(bool disposing) { if (disposing && wallpaper != null) wallpaper.Dispose(); base.Dispose(disposing); }
    }

    internal sealed class MainForm : Form
    {
        private static readonly Color Background = Color.FromArgb(16, 21, 25);
        private static readonly Color Surface = Color.FromArgb(25, 31, 36);
        private static readonly Color Accent = Color.FromArgb(244, 195, 64);
        private readonly ChoiceList equipment = new ChoiceList { Name = "installList" };
        private readonly Button start = ActionButton("Apply changes");
        private readonly Button details = ActionButton("Activity");
        private readonly TextBox log = new TextBox { Name = "liveLog", Multiline = true, ReadOnly = true, Dock = DockStyle.Fill, ScrollBars = ScrollBars.Both,
            WordWrap = false, BackColor = Surface, ForeColor = Color.Gainsboro, BorderStyle = BorderStyle.None };
        private readonly TextBox errors = new TextBox { Name = "errorDetails", Multiline = true, ReadOnly = true, Dock = DockStyle.Fill, ScrollBars = ScrollBars.Vertical,
            WordWrap = true, BackColor = Surface, ForeColor = Color.Gainsboro, BorderStyle = BorderStyle.None };
        private readonly ComboBox deviceType = new ComboBox { Name = "deviceType", DropDownStyle = ComboBoxStyle.DropDownList, Width = 112, FlatStyle = FlatStyle.Flat, BackColor = Surface, ForeColor = Color.White };
        private readonly ComboBox manufacturer = new ComboBox { Name = "manufacturer", DropDownStyle = ComboBoxStyle.DropDownList, Width = 130, FlatStyle = FlatStyle.Flat, BackColor = Surface, ForeColor = Color.White };
        private readonly FlowLayoutPanel cleanupHost = new FlowLayoutPanel { Name = "cleanupSections", Dock = DockStyle.Fill, AutoScroll = true, WrapContents = false,
            FlowDirection = FlowDirection.TopDown, Margin = Padding.Empty, BackColor = Surface };
        private readonly List<CleanupSection> sections = new List<CleanupSection>();
        private readonly Dictionary<string, bool> cleanupSelection = new Dictionary<string, bool>();
        private readonly List<CleanupItem> cleanupItems = new List<CleanupItem>();
        private readonly List<Button> selectionButtons = new List<Button>();
        private readonly HashSet<string> displayedIssues = new HashSet<string>();
        private readonly TabControl detailTabs = new TabControl { Name = "detailTabs", Dock = DockStyle.Fill, Visible = false };
        private readonly Label status = new Label { Name = "currentTask", Text = "", Dock = DockStyle.Top, Height = 35, ForeColor = Color.Silver };
        private readonly ProgressBar progress = new ProgressBar { Dock = DockStyle.Bottom, Height = 3, Visible = false };
        private readonly DesktopPreview desktopPreview = new DesktopPreview();
        private readonly TableLayoutPanel layout = new TableLayoutPanel();
        private string wallpaperPath = "", lockScreenPath = "";
        private bool syncingImages, refreshingCleanup;
        public Func<bool, string> ImagePicker { get; set; }
        public Func<bool> ConfirmLockScreen { get; set; }
        private Process running;
        private string directory, output;
        private bool receivedResult;
        private string primaryCode = "";
        private sealed class CleanupItem {
            public string Id, Label, Vendor, Group; public bool DefaultSelected;
            public override string ToString() { return Label; }
        }

        public MainForm()
        {
            Text = "TinnosDebloat-Win11"; BackColor = Background; ForeColor = Color.White;
            Font = new Font("Segoe UI", 10); ClientSize = new Size(Math.Min(1420, Screen.PrimaryScreen.WorkingArea.Width - 48), Math.Min(790, Screen.PrimaryScreen.WorkingArea.Height - 70)); MinimumSize = new Size(1200, 700);
            using (Stream icon = Assembly.GetExecutingAssembly().GetManifestResourceStream("Brand.app.ico")) Icon = new Icon(icon);
            StartPosition = FormStartPosition.CenterScreen;
            layout.Dock = DockStyle.Fill; layout.Padding = new Padding(28, 20, 28, 20); layout.ColumnCount = 1; layout.RowCount = 4;
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 92)); layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 66)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 0));
            TableLayoutPanel header = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Margin = Padding.Empty };
            header.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 68)); header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            PictureBox emblem = new PictureBox { Name = "brandEmblem", SizeMode = PictureBoxSizeMode.Zoom, Dock = DockStyle.Fill, Margin = new Padding(0, 6, 16, 18) };
            using (Stream image = Assembly.GetExecutingAssembly().GetManifestResourceStream("Brand.emblem.png"))
            using (Bitmap source = new Bitmap(image)) emblem.Image = source.Clone(new Rectangle(source.Width / 5, source.Height / 8, source.Width * 3 / 5, source.Height * 3 / 4), System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            header.Controls.Add(emblem);
            header.Controls.Add(new Label { Name = "brandTitle", Text = "TINNOS DEBLOAT", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft,
                Font = new Font("Segoe UI Semibold", 25), ForeColor = Accent, Margin = new Padding(0, 0, 0, 12) });
            layout.Controls.Add(header, 0, 0);
            equipment.Items.Add(new CleanupItem { Id = "GoogleDrive", Label = "Google Drive" }, true);
            equipment.Items.Add(new CleanupItem { Id = "Office", Label = "Microsoft 365 Office" }, true);
            equipment.Items.Add(new CleanupItem { Id = "Chrome", Label = "Google Chrome" }, true);
            equipment.Items.Add(new CleanupItem { Id = "TranslucentTB", Label = "TranslucentTB" }, false);
            equipment.Items.Add(new CleanupItem { Id = "Wallpaper", Label = "Wallpaper" }, false);
            equipment.Items.Add(new CleanupItem { Id = "LockScreen", Label = "Lock screen" }, false);
            ImagePicker = BrowseImage;
            ConfirmLockScreen = delegate { return MessageBox.Show(this, "Use this image on the lock screen as well?", "Lock screen", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes; };
            equipment.ItemCheck += EquipmentChanged;
            TableLayoutPanel gear = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1, Margin = Padding.Empty, BackColor = Surface };
            gear.RowStyles.Add(new RowStyle(SizeType.Absolute, 42)); gear.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            gear.Controls.Add(SelectionRow("gear", delegate { SelectAllGear(true); }, delegate { SelectAllGear(false); })); gear.Controls.Add(equipment);
            deviceType.Items.AddRange(new object[] { "Desktop", "Laptop" }); manufacturer.Items.AddRange(new object[] { "Other / None", "ASUS", "Dell" });
            deviceType.SelectedIndex = 0; manufacturer.SelectedIndex = 0; manufacturer.Enabled = false;
            TableLayoutPanel wasps = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 3, ColumnCount = 1, Margin = Padding.Empty, BackColor = Surface };
            wasps.RowStyles.Add(new RowStyle(SizeType.Absolute, 45)); wasps.RowStyles.Add(new RowStyle(SizeType.Absolute, 43)); wasps.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            wasps.Controls.Add(Row(new Label { Text = "Device", AutoSize = true, Padding = new Padding(0, 5, 6, 0), ForeColor = Color.Silver }, deviceType,
                new Label { Text = "Brand", AutoSize = true, Padding = new Padding(12, 5, 6, 0), ForeColor = Color.Silver }, manufacturer));
            wasps.Controls.Add(SelectionRow("cleanup", delegate { SelectAllCleanup(true); }, delegate { SelectAllCleanup(false); })); wasps.Controls.Add(cleanupHost);
            foreach (string name in new string[] { "Apps", "Services", "Appearance", "Manufacturer" }) {
                CleanupSection section = new CleanupSection(name, name == "Appearance" ? "Windows & appearance" : name == "Manufacturer" ? "Manufacturer apps" : name, name == "Apps");
                sections.Add(section); cleanupHost.Controls.Add(section);
                section.List.ItemCheck += delegate(object sender, ItemCheckEventArgs e) {
                    if (!refreshingCleanup) {
                        ChoiceList list = (ChoiceList)sender; CleanupItem item = (CleanupItem)list.Items[e.Index];
                        cleanupSelection[item.Id] = e.NewValue == CheckState.Checked; RefreshPreview();
                    }
                };
            }
            cleanupHost.SizeChanged += delegate { SizeSections(); };
            TableLayoutPanel choices = new TableLayoutPanel { Name = "workspaceColumns", Dock = DockStyle.Fill, ColumnCount = 3, Margin = Padding.Empty };
            choices.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 24)); choices.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 43)); choices.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 33));
            choices.Controls.Add(ActionSection("EQUIP GEAR", gear,
                "Choose programs to install. Wallpaper and Lock screen open the image picker when checked. Wallpaper also asks whether to use the same image on the lock screen. Uncheck to cancel that image; rechecking opens the picker again. Select all includes the image choices and their dialogs.\n\nOffice: PT-BR, 64-bit; Word, Excel and PowerPoint. TranslucentTB uses Microsoft Store. Image changes apply to the account running this app after Apply changes."));
            choices.Controls.Add(ActionSection("REMOVE WASPS", wasps,
                "Checked actions run after Apply changes. Select all includes optional and high-impact actions in all sections for the current device/brand, even when collapsed. Clear all leaves them unchanged.\n\nASUS and Dell actions are shown only for the chosen laptop brand. Disabling optional services may affect battery settings, hotkeys, GPU recovery or Windows Update. Cryptographic Services is not disk encryption. Armoury Crate requires ASUS's uninstall tool.\n\nSearch and Start policies require supported updated Windows editions and a restart. Expand each section to review the action labels."));
            choices.Controls.Add(ActionSection("DESKTOP PREVIEW", desktopPreview, null)); layout.Controls.Add(choices, 0, 1);
            using (Stream data = Assembly.GetExecutingAssembly().GetManifestResourceStream("Payload.debloat-catalog.json"))
            using (StreamReader reader = new StreamReader(data)) {
                foreach (object entry in (object[])ResultChannel.Serializer().DeserializeObject(reader.ReadToEnd())) {
                    Dictionary<string, object> item = (Dictionary<string, object>)entry; string vendor = TextValue(item, "Vendor");
                    bool service = Items(item, "Services").Length > 0;
                    CleanupItem choice = new CleanupItem { Id = TextValue(item, "Id"), Label = TextValue(item, "Name"), Vendor = vendor,
                        Group = service ? "Services" : vendor == "Dell" || vendor == "ASUS" ? "Manufacturer" : Value(item, "Setting") != null ? "Appearance" : "Apps",
                        DefaultSelected = !(Value(item, "DefaultSelected") is bool) || (bool)Value(item, "DefaultSelected") };
                    cleanupItems.Add(choice); cleanupSelection[choice.Id] = ((vendor == "Dell" || vendor == "ASUS") && (!(Value(item, "SelectWithVendor") is bool) || (bool)Value(item, "SelectWithVendor"))) || choice.DefaultSelected;
                }
            }
            RefreshCleanup(); deviceType.SelectedIndexChanged += delegate { manufacturer.Enabled = deviceType.SelectedIndex == 1; RefreshCleanup(); };
            manufacturer.SelectedIndexChanged += delegate { RefreshCleanup(); };
            start.Width = 218; details.Width = 120; details.Name = "detailsButton"; start.Name = "startButton";
            start.BackColor = Accent; start.ForeColor = Background; start.FlatAppearance.BorderSize = 0; start.FlatAppearance.MouseOverBackColor = Color.FromArgb(255, 212, 99); start.FlatAppearance.MouseDownBackColor = Color.FromArgb(223, 170, 38);
            layout.Controls.Add(ActionRow(details, start), 0, 2);
            foreach (string name in new string[] { "Log", "Errors" }) detailTabs.TabPages.Add(new TabPage(name) { BackColor = Surface, Padding = new Padding(12) });
            Panel live = new Panel { Dock = DockStyle.Fill, BackColor = Surface }; live.Controls.Add(log); live.Controls.Add(status);
            detailTabs.TabPages[0].Controls.Add(live); detailTabs.TabPages[1].Controls.Add(errors);
            layout.Controls.Add(detailTabs, 0, 3); Controls.Add(layout); Controls.Add(progress);
            start.Click += delegate { Run(); }; details.Click += delegate { SetDetails(!detailTabs.Visible); };
            FormClosing += delegate(object sender, FormClosingEventArgs e) { if (running != null) { e.Cancel = true; status.Text = "An operation is running. Wait for the result."; SetDetails(true); } };
            RefreshPreview();
        }
        private string BrowseImage(bool lockScreen)
        {
            using (OpenFileDialog picker = new OpenFileDialog { Title = lockScreen ? "Choose lock-screen image" : "Choose wallpaper",
                Filter = "Images (*.jpg;*.jpeg;*.png;*.bmp)|*.jpg;*.jpeg;*.png;*.bmp", CheckFileExists = true, Multiselect = false })
                return picker.ShowDialog(this) == DialogResult.OK ? picker.FileName : null;
        }
        private void EquipmentChanged(object sender, ItemCheckEventArgs e)
        {
            if (syncingImages) return;
            CleanupItem item = (CleanupItem)equipment.Items[e.Index];
            if (item.Id == "Wallpaper" || item.Id == "LockScreen") {
                if (e.NewValue == CheckState.Checked) {
                    string path = ImagePicker(item.Id == "LockScreen");
                    if (string.IsNullOrEmpty(path)) { e.NewValue = CheckState.Unchecked; return; }
                    try {
                        using (Image image = Image.FromFile(path)) if (image.Width < 1 || image.Height < 1 || (long)image.Width * image.Height > 100000000)
                            throw new InvalidDataException("Choose an image up to 100 megapixels.");
                        if (item.Id == "Wallpaper") {
                            wallpaperPath = path;
                            if (ConfirmLockScreen()) { lockScreenPath = path; SetImageCheck(5, true); }
                        } else lockScreenPath = path;
                    } catch (Exception error) {
                        e.NewValue = CheckState.Unchecked;
                        MessageBox.Show(this, error.Message, "Cannot open image", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    }
                } else if (item.Id == "Wallpaper") {
                    if (lockScreenPath == wallpaperPath) { lockScreenPath = ""; SetImageCheck(5, false); }
                    wallpaperPath = "";
                } else lockScreenPath = "";
            }
            RefreshPreview(e.Index, e.NewValue);
        }
        private void SetImageCheck(int index, bool check)
        {
            syncingImages = true;
            try { equipment.SetItemChecked(index, check); } finally { syncingImages = false; }
        }
        public void SetImageSelections(string wallpaper, string lockScreen)
        {
            wallpaperPath = wallpaper ?? ""; lockScreenPath = lockScreen ?? "";
            SetImageCheck(4, wallpaperPath != ""); SetImageCheck(5, lockScreenPath != ""); RefreshPreview();
        }
        public void SelectAllGear(bool selected)
        {
            for (int i = 0; i < equipment.Items.Count; i++) if (equipment.GetItemChecked(i) != selected) equipment.SetItemChecked(i, selected);
            RefreshPreview();
        }
        public void SelectAllCleanup(bool selected)
        {
            foreach (CleanupSection section in sections) for (int i = 0; i < section.List.Items.Count; i++) section.List.SetItemChecked(i, selected);
            RefreshPreview();
        }
        public void SetCleanupChecked(string id, bool selected)
        {
            foreach (CleanupSection section in sections) for (int i = 0; i < section.List.Items.Count; i++)
                if (((CleanupItem)section.List.Items[i]).Id == id) { section.List.SetItemChecked(i, selected); return; }
            throw new ArgumentException("Cleanup action is not available for the selected device: " + id);
        }
        public int VisibleCleanupCount { get { int count = 0; foreach (CleanupSection section in sections) count += section.List.Items.Count; return count; } }
        public void SetCleanupSectionExpanded(string name, bool expanded)
        {
            foreach (CleanupSection section in sections) if (section.Name == "group" + name) { section.SetExpanded(expanded); return; }
            throw new ArgumentException("Unknown cleanup section.");
        }
        private bool IsAvailable(CleanupItem item)
        {
            return item.Vendor != "Dell" && item.Vendor != "ASUS" || deviceType.SelectedIndex == 1 && item.Vendor == Convert.ToString(manufacturer.SelectedItem);
        }
        private void RefreshCleanup()
        {
            refreshingCleanup = true;
            try {
                foreach (CleanupSection section in sections) {
                    section.List.BeginUpdate(); section.List.Items.Clear();
                    foreach (CleanupItem item in cleanupItems) if (IsAvailable(item) && section.Name == "group" + item.Group) section.List.Items.Add(item, cleanupSelection[item.Id]);
                    section.List.EndUpdate(); section.Visible = section.List.Items.Count > 0; section.SetExpanded(section.Expanded);
                }
            } finally { refreshingCleanup = false; }
            SizeSections(); RefreshPreview();
        }
        private void SizeSections() { foreach (CleanupSection section in sections) section.Width = Math.Max(60, cleanupHost.ClientSize.Width - SystemInformation.VerticalScrollBarWidth - 2); }
        private void RefreshPreview() { RefreshPreview(-1, CheckState.Unchecked); }
        private void RefreshPreview(int pendingIndex, CheckState pendingState)
        {
            List<string> apps = new List<string>(); bool translucent = false;
            for (int i = 0; i < 4; i++) if (i == pendingIndex ? pendingState == CheckState.Checked : equipment.GetItemChecked(i)) {
                CleanupItem item = (CleanupItem)equipment.Items[i]; apps.Add(item.Id == "Office" ? "Microsoft 365" : item.Label);
                if (item.Id == "TranslucentTB") translucent = true;
            }
            desktopPreview.Translucent = translucent;
            bool hideIcons; desktopPreview.DesktopIcons = !cleanupSelection.TryGetValue("DesktopIcons", out hideIcons) || !hideIcons;
            bool moss; desktopPreview.Moss = cleanupSelection.TryGetValue("BackgroundMoss", out moss) && moss;
            desktopPreview.UpdateDesktop(wallpaperPath, apps.ToArray());
        }
        private void SetDetails(bool show)
        {
            detailTabs.Visible = show; layout.RowStyles[3].Height = show ? 205 : 0;
            int availableHeight = Screen.FromControl(this).WorkingArea.Height - SystemInformation.CaptionHeight - 26;
            ClientSize = new Size(ClientSize.Width, Math.Min(availableHeight, show ? 990 : 790));
            details.Text = show ? "Hide activity" : "Activity";
        }
        private static Button ActionButton(string text)
        {
            Button button = new Button { Text = text, FlatStyle = FlatStyle.Flat, Width = 124, Height = 40,
                Font = new Font("Segoe UI Semibold", 10), BackColor = Surface, ForeColor = Color.Gainsboro, Margin = Padding.Empty, Cursor = Cursors.Hand };
            button.FlatAppearance.BorderColor = Color.FromArgb(59, 72, 81); button.FlatAppearance.MouseOverBackColor = Color.FromArgb(45, 57, 65); return button;
        }
        private Control SelectionRow(string name, Action select, Action clear)
        {
            Button all = ActionButton("Select all"), none = ActionButton("Clear all"); all.Name = name + "SelectAll"; none.Name = name + "ClearAll";
            foreach (Button button in new Button[] { all, none }) { button.Width = 94; button.Height = 30; button.Font = new Font("Segoe UI", 9); button.FlatAppearance.BorderSize = 0; button.ForeColor = Color.FromArgb(169, 186, 198); selectionButtons.Add(button); }
            all.Click += delegate { select(); }; none.Click += delegate { clear(); }; return Row(all, none);
        }
        private static FlowLayoutPanel Row(params Control[] controls)
        {
            FlowLayoutPanel panel = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, WrapContents = false, Margin = Padding.Empty, BackColor = Surface };
            panel.Controls.AddRange(controls); return panel;
        }
        private static Button CreateHelpButton(string name, string title, string guidance)
        {
            Button button = ActionButton("?"); button.Name = name; button.AccessibleName = title + " help"; button.AccessibleDescription = guidance;
            button.Size = new Size(26, 26); button.ForeColor = Color.FromArgb(139, 155, 166); button.FlatAppearance.BorderSize = 0;
            button.Click += delegate { MessageBox.Show(button.FindForm(), guidance, title, MessageBoxButtons.OK, MessageBoxIcon.Information); }; return button;
        }
        private static Control ActionSection(string title, Control content, string note)
        {
            SurfaceCard card = new SurfaceCard { Dock = DockStyle.Fill, Margin = new Padding(0, 0, 14, 0) };
            TableLayoutPanel inside = new TableLayoutPanel { Dock = DockStyle.Fill, BackColor = Surface, ColumnCount = 1, RowCount = 2, Margin = Padding.Empty };
            inside.RowStyles.Add(new RowStyle(SizeType.Absolute, 47)); inside.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            TableLayoutPanel heading = new TableLayoutPanel { Dock = DockStyle.Fill, BackColor = Surface, ColumnCount = 2, Margin = Padding.Empty };
            heading.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); heading.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 28));
            heading.Controls.Add(new Label { Text = title, AutoSize = true, ForeColor = Color.FromArgb(222, 230, 235), Font = new Font("Segoe UI Semibold", 11), Margin = new Padding(0, 4, 0, 0) });
            if (note != null) heading.Controls.Add(CreateHelpButton(title == "EQUIP GEAR" ? "gearHelp" : "waspsHelp", title, note));
            inside.Controls.Add(heading); inside.Controls.Add(content); card.Controls.Add(inside); return card;
        }
        private static Control ActionRow(Control left, Control right)
        {
            TableLayoutPanel row = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Margin = new Padding(0, 16, 14, 0) };
            row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50)); row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            left.Anchor = AnchorStyles.Left; right.Anchor = AnchorStyles.Right; row.Controls.Add(left, 0, 0); row.Controls.Add(right, 1, 0); return row;
        }
        private void Append(string text)
        {
            if (text == null || IsDisposed) return;
            if (InvokeRequired) { BeginInvoke(new Action<string>(Append), text); return; }
            if (text.StartsWith("TINNOS_EVENT:", StringComparison.Ordinal)) {
                try { ApplyEvent(Encoding.UTF8.GetString(Convert.FromBase64String(text.Substring("TINNOS_EVENT:".Length)))); }
                catch (Exception error) { DisplayError("TNO-904", error.Message); }
                return;
            }
            if (text.StartsWith(ResultChannel.Prefix, StringComparison.Ordinal)) {
                try { ApplyResult(ResultChannel.Decode(text)); }
                catch (Exception error) { DisplayError("TNO-904", error.Message); }
                return;
            }
            log.AppendText(text + Environment.NewLine);
        }
        private void Busy(bool busy)
        {
            foreach (Control item in new Control[] { equipment, cleanupHost, start, deviceType, manufacturer }) item.Enabled = !busy;
            foreach (Button button in selectionButtons) button.Enabled = !busy;
            progress.Visible = busy;
            manufacturer.Enabled = !busy && deviceType.SelectedIndex == 1;
            progress.Style = busy ? ProgressBarStyle.Marquee : ProgressBarStyle.Blocks;
        }
        public string SelectedConfiguration()
        {
            List<string> install = new List<string>(), remove = new List<string>();
            foreach (CleanupItem item in equipment.CheckedItems) if (item.Id != "Wallpaper" && item.Id != "LockScreen") install.Add(item.Id);
            foreach (CleanupItem item in cleanupItems) if (IsAvailable(item) && cleanupSelection[item.Id]) remove.Add(item.Id);
            Dictionary<string, object> config = new Dictionary<string, object> {
                { "LicenseEdition", "Business" }, { "Architecture", "64" }, { "Languages", new string[] { "pt-br" } }, { "Channel", "Current" },
                { "InstallItems", install.ToArray() }, { "RemoveItems", remove.ToArray() }
            };
            if (wallpaperPath != "") config.Add("WallpaperPath", wallpaperPath);
            if (lockScreenPath != "") config.Add("LockScreenPath", lockScreenPath);
            return ResultChannel.Serializer().Serialize(config);
        }
        private bool HasSelectedCleanup() { foreach (CleanupItem item in cleanupItems) if (IsAvailable(item) && cleanupSelection[item.Id]) return true; return false; }
        private void Run()
        {
            if (running != null) return;
            try
            {
                if (equipment.CheckedItems.Count == 0 && !HasSelectedCleanup() && wallpaperPath == "" && lockScreenPath == "") {
                    status.Text = "Nothing selected. Mark the actions you want to execute.";
                    Append(status.Text); SetDetails(true); return;
                }
                string config = SelectedConfiguration();
                directory = Payload.Extract(); output = Path.Combine(directory, "Work");
                string configPath = Path.Combine(directory, "config.json");
                File.WriteAllText(configPath, config, new UTF8Encoding(false));
                receivedResult = false; primaryCode = ""; log.Clear(); errors.Clear(); displayedIssues.Clear(); detailTabs.TabPages[1].Text = "Errors";
                Append("Starting. Results remain in memory. Working files: " + output);
                running = new Process { StartInfo = Payload.Command(directory, configPath, "Deploy", output), EnableRaisingEvents = true };
                running.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) { Append(e.Data); };
                running.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { Append(e.Data); };
                Process child = running;
                child.Exited += delegate { ThreadPool.QueueUserWorkItem(delegate {
                    child.WaitForExit(); BeginInvoke(new Action(delegate { Finish(child); }));
                }); };
                Busy(true); SetDetails(true); detailTabs.SelectedIndex = 0; status.Text = "Starting inventory...";
                running.Start(); running.BeginOutputReadLine(); running.BeginErrorReadLine();
            }
            catch (Exception error) {
                DisplayError("TNO-901", error.Message);
                if (running != null) { running.Dispose(); running = null; }
                Busy(false);
            }
        }
        private void Finish(Process child)
        {
            int code = child.ExitCode; Append("Exit code: " + code);
            if (!receivedResult) {
                if (primaryCode == "") {
                    bool blocked = log.Text.IndexOf("PSSecurityException", StringComparison.OrdinalIgnoreCase) >= 0 || log.Text.IndexOf("UnauthorizedAccess", StringComparison.OrdinalIgnoreCase) >= 0;
                    DisplayError(blocked ? "TNO-902" : "TNO-903", "Worker exit code: " + code + ". Review the Log tab.");
                }
            } else status.Text = (primaryCode == "" ? "" : "[" + primaryCode + "] ") + (code == 0 ? "Complete. View Details."
                : code == 2 ? "Finished with issues. See Errors and retry failed tasks."
                : code == 3010 ? "Action needed. View Details." : "Check failed. View Details.");
            child.Dispose(); running = null;
            Busy(false); SetDetails(true);
        }
        private void DisplayError(string code, string message)
        {
            primaryCode = code; errors.AppendText(ResultChannel.ErrorText(code, message) + Environment.NewLine + Environment.NewLine);
            status.Text = "[" + code + "] View Details."; SetDetails(true); detailTabs.SelectedIndex = 1;
        }
        private void ShowIssue(Dictionary<string, object> issue)
        {
            string key = TextValue(issue, "Code") + "|" + TextValue(issue, "Stage") + "|" + TextValue(issue, "Message") + "|" + TextValue(issue, "Severity");
            if (!displayedIssues.Add(key)) return;
            string code = TextValue(issue, "Code"), severity = TextValue(issue, "Severity");
            if (primaryCode == "" && severity != "Warning") primaryCode = code;
            string text = "[" + code + "] " + TextValue(issue, "Title") + " (" + severity + ")" + Environment.NewLine
                + TextValue(issue, "Stage") + ": " + TextValue(issue, "Message") + Environment.NewLine
                + "Next step: " + TextValue(issue, "Action") + Environment.NewLine
                + (Value(issue, "NativeCode") == null ? "" : "Native exit code: " + TextValue(issue, "NativeCode") + Environment.NewLine);
            errors.AppendText(text + Environment.NewLine);
            log.AppendText(text + Environment.NewLine);
            detailTabs.TabPages[1].Text = "Errors (" + displayedIssues.Count + ")";
        }
        public void ApplyEvent(string json)
        {
            Dictionary<string, object> entry = ResultChannel.Serializer().DeserializeObject(json) as Dictionary<string, object>;
            if (entry == null || Value(entry, "Kind") == null) throw new InvalidDataException("Invalid live event.");
            string kind = TextValue(entry, "Kind"), task = TextValue(entry, "Task"), message = TextValue(entry, "Message");
            status.Text = task + ": " + message;
            if (kind == "Issue") {
                Dictionary<string, object> issue = Value(entry, "Issue") as Dictionary<string, object>;
                if (issue == null) throw new InvalidDataException("Live issue has no error details.");
                ShowIssue(issue);
            } else log.AppendText("[" + DateTime.Now.ToString("HH:mm:ss", CultureInfo.InvariantCulture) + "] "
                + (kind == "Success" ? "OK - " : "") + task + ": " + message + Environment.NewLine);
        }
        private static object Value(Dictionary<string, object> map, string key)
        {
            object value; return map != null && map.TryGetValue(key, out value) ? value : null;
        }
        private static string TextValue(Dictionary<string, object> map, string key) { return Convert.ToString(Value(map, key)); }
        private static object[] Items(Dictionary<string, object> map, string key) { return Value(map, key) as object[] ?? new object[0]; }
        public void ApplyResult(string json)
        {
            Dictionary<string, object> report = ResultChannel.Serializer().DeserializeObject(json) as Dictionary<string, object>;
            if (report == null || Value(report, "Status") == null) throw new InvalidDataException("Worker result has no status.");
            log.AppendText(Environment.NewLine + "Run finished: " + TextValue(report, "Status") + Environment.NewLine);
            Dictionary<string, object> restore = Value(report, "RestorePoint") as Dictionary<string, object>;
            if (restore != null) log.AppendText("Restore point: " + TextValue(restore, "Status") + Environment.NewLine);
            Dictionary<string, object> activation = Value(report, "Activation") as Dictionary<string, object>;
            if (activation != null) log.AppendText("Office activation: " + TextValue(activation, "Status") + ". " + TextValue(activation, "Reason") + Environment.NewLine);
            foreach (object item in Items(report, "Applications")) {
                Dictionary<string, object> app = item as Dictionary<string, object>;
                log.AppendText(TextValue(app, "Name") + ": " + TextValue(app, "Status") + Environment.NewLine);
            }
            foreach (object item in Items(report, "Checks")) {
                Dictionary<string, object> check = item as Dictionary<string, object>;
                bool pass = Value(check, "Pass") is bool && (bool)Value(check, "Pass");
                bool required = !(Value(check, "Required") is bool) || (bool)Value(check, "Required");
                object evidence = Value(check, "Detail");
                if (required || !pass && TextValue(report, "Status") != "Complete")
                    log.AppendText("Verify " + TextValue(check, "Name") + ": " + (pass ? "Passed" : required ? "Failed" : "Not verified")
                        + (pass || evidence == null ? "" : ". " + ResultChannel.Serializer().Serialize(evidence)) + Environment.NewLine);
            }
            foreach (string severity in new string[] { "Error", "Pending", "Warning" })
                foreach (object item in Items(report, "Issues")) {
                    Dictionary<string, object> issue = item as Dictionary<string, object>;
                    if (TextValue(issue, "Severity") != severity) continue;
                    ShowIssue(issue);
                }
            foreach (object note in Items(report, "Notes")) log.AppendText(Convert.ToString(note) + Environment.NewLine);
            receivedResult = true; SetDetails(true); detailTabs.SelectedIndex = primaryCode == "" ? 0 : 1;
        }
    }
}
