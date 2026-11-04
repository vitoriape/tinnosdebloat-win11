using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: AssemblyTitle("TinnosDebloat-Win11")]
[assembly: AssemblyDescription("Windows 11 provisioning and Teams removal")]
[assembly: AssemblyVersion("2.0.0.0")]

namespace TinnosDebloat
{
    public static class Payload
    {
        public static readonly string[] Files = { "Invoke-Provisioning.ps1", "Invoke-UserCleanup.ps1", "Provisioning.psm1", "Check-OfficeActivation.ps1", "config.example.json" };
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
                RedirectStandardOutput = true, RedirectStandardError = true
            };
        }
    }

    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            if (args.Length > 0) return CommandLine(args);
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(Ui.Create()); return 0;
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
                if (output == null) output = Path.Combine(directory, "Reports");
                using (StreamWriter log = new StreamWriter(Path.Combine(directory, "launcher.log"), false, Encoding.UTF8))
                using (Process process = new Process { StartInfo = Payload.Command(directory, config, mode, output) })
                {
                    object sync = new object();
                    DataReceivedEventHandler append = delegate(object sender, DataReceivedEventArgs e) {
                        if (e.Data != null) lock (sync) { log.WriteLine(e.Data); log.Flush(); }
                    };
                    process.OutputDataReceived += append; process.ErrorDataReceived += append;
                    process.Start(); process.BeginOutputReadLine(); process.BeginErrorReadLine(); process.WaitForExit();
                    log.WriteLine("Exit code: " + process.ExitCode); return process.ExitCode;
                }
            }
            catch (Exception error) {
                try { if (directory != null) File.AppendAllText(Path.Combine(directory, "launcher.log"), error.ToString()); } catch { }
                return 1;
            }
        }
    }

    public static class Ui
    {
        public static Form Create() { return new MainForm(); }
    }

    internal sealed class MainForm : Form
    {
        private static readonly Color Background = Color.FromArgb(23, 29, 35);
        private static readonly Color Surface = Color.FromArgb(38, 46, 54);
        private static readonly Color Accent = Color.FromArgb(218, 180, 103);
        private readonly CheckBox portuguese = Toggle("PT-BR", true);
        private readonly CheckBox english = Toggle("English", true);
        private readonly CheckBox access = Toggle("Access", false);
        private readonly CheckBox oneDrive = Toggle("Exclude OneDrive", true);
        private readonly CheckBox outlook = Toggle("Exclude new Outlook", true);
        private readonly Button audit = ActionButton("Audit");
        private readonly Button start = ActionButton("Start");
        private readonly Button reports = ActionButton("Reports");
        private readonly Button details = ActionButton("Details");
        private readonly TextBox log = new TextBox { Multiline = true, ReadOnly = true, Dock = DockStyle.Fill, ScrollBars = ScrollBars.Both,
            WordWrap = false, BackColor = Surface, ForeColor = Color.Gainsboro, BorderStyle = BorderStyle.None, Visible = false };
        private readonly Label status = new Label { Text = "Ready", AutoSize = true, ForeColor = Color.Gainsboro, Margin = new Padding(3, 12, 3, 8) };
        private readonly ProgressBar progress = new ProgressBar { Dock = DockStyle.Fill, Height = 4 };
        private Process running;
        private string directory, output;
        private StreamWriter logFile;

        public MainForm()
        {
            Text = "TinnosDebloat-Win11"; BackColor = Background; ForeColor = Color.White;
            Font = new Font("Segoe UI", 10); ClientSize = new Size(610, 245); MinimumSize = new Size(626, 284);
            StartPosition = FormStartPosition.CenterScreen;
            TableLayoutPanel layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(20), ColumnCount = 1, RowCount = 6 };
            for (int i = 0; i < 4; i++) layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 5)); layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            layout.Controls.Add(Row(portuguese, english));
            layout.Controls.Add(Row(access, oneDrive, outlook));
            layout.Controls.Add(Row(audit, start, reports, details));
            layout.Controls.Add(status); layout.Controls.Add(progress); layout.Controls.Add(log); Controls.Add(layout);
            start.BackColor = Accent; start.ForeColor = Background; reports.Enabled = false;
            audit.Click += delegate { Run("Audit"); }; start.Click += delegate { Run("Deploy"); };
            details.Click += delegate {
                log.Visible = !log.Visible; details.Text = log.Visible ? "Hide details" : "Details";
                ClientSize = new Size(ClientSize.Width, log.Visible ? 510 : 245);
            };
            reports.Click += delegate { if (output != null && Directory.Exists(output)) Process.Start("explorer.exe", Payload.Quote(output)); };
            FormClosing += delegate(object sender, FormClosingEventArgs e) {
                if (running != null) { e.Cancel = true; status.Text = "An operation is running. Wait for the report."; }
            };
        }
        private static CheckBox Toggle(string text, bool selected)
        {
            CheckBox button = new CheckBox { Text = text, Checked = selected, Appearance = Appearance.Button, AutoSize = false,
                Width = text.Contains("Outlook") ? 194 : text.Contains("OneDrive") ? 166 : 124, Height = 38,
                TextAlign = ContentAlignment.MiddleCenter, FlatStyle = FlatStyle.Flat, Padding = Padding.Empty, Margin = new Padding(3, 3, 7, 5) };
            button.FlatAppearance.BorderColor = Accent;
            Action recolor = delegate { button.BackColor = button.Checked ? Accent : Surface; button.ForeColor = button.Checked ? Background : Color.Gainsboro; };
            button.CheckedChanged += delegate { recolor(); }; recolor(); return button;
        }
        private static Button ActionButton(string text)
        {
            Button button = new Button { Text = text, FlatStyle = FlatStyle.Flat, Width = 124, Height = 38,
                BackColor = Surface, ForeColor = Color.Gainsboro, Margin = new Padding(3, 8, 7, 3) };
            button.FlatAppearance.BorderColor = Accent; return button;
        }
        private static FlowLayoutPanel Row(params Control[] controls)
        {
            FlowLayoutPanel panel = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, WrapContents = false, Margin = Padding.Empty };
            panel.Controls.AddRange(controls); return panel;
        }
        private void Append(string text)
        {
            if (text == null || IsDisposed) return;
            if (InvokeRequired) { BeginInvoke(new Action<string>(Append), text); return; }
            log.AppendText(text + Environment.NewLine);
            if (logFile != null) { logFile.WriteLine(text); logFile.Flush(); }
        }
        private void Busy(bool busy)
        {
            foreach (Control item in new Control[] { portuguese, english, access, oneDrive, outlook, audit, start }) item.Enabled = !busy;
            progress.Style = busy ? ProgressBarStyle.Marquee : ProgressBarStyle.Blocks;
        }
        private void Run(string mode)
        {
            if (running != null) return;
            if (!portuguese.Checked && !english.Checked) { status.Text = "Select PT-BR or English."; return; }
            try
            {
                directory = Payload.Extract(); output = Path.Combine(directory, "Reports");
                List<string> languages = new List<string>(); if (portuguese.Checked) languages.Add("pt-br"); if (english.Checked) languages.Add("en-us");
                Dictionary<string, object> config = new Dictionary<string, object> {
                    { "LicenseEdition", "Business" }, { "Architecture", "64" }, { "Languages", languages }, { "Channel", "Current" },
                    { "IncludeAccess", access.Checked }, { "ExcludeOneDrive", oneDrive.Checked }, { "ExcludeNewOutlook", outlook.Checked }
                };
                string configPath = Path.Combine(directory, "config.json");
                File.WriteAllText(configPath, new JavaScriptSerializer().Serialize(config), new UTF8Encoding(false));
                logFile = new StreamWriter(Path.Combine(directory, "launcher.log"), false, Encoding.UTF8);
                log.Clear(); Append("Mode: " + mode + ". Reports: " + output);
                reports.Enabled = false; running = new Process { StartInfo = Payload.Command(directory, configPath, mode, output), EnableRaisingEvents = true };
                running.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) { Append(e.Data); };
                running.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { Append(e.Data); };
                Process child = running;
                child.Exited += delegate { ThreadPool.QueueUserWorkItem(delegate {
                    child.WaitForExit(); BeginInvoke(new Action(delegate { Finish(child, mode); }));
                }); };
                Busy(true); status.Text = mode == "Deploy" ? "Creating restore point and preparing deployment..." : "Auditing...";
                running.Start(); running.BeginOutputReadLine(); running.BeginErrorReadLine();
            }
            catch (Exception error) {
                Append(error.Message); status.Text = "Unable to start. Open Details.";
                if (running != null) { running.Dispose(); running = null; }
                if (logFile != null) { logFile.Dispose(); logFile = null; } Busy(false);
            }
        }
        private void Finish(Process child, string mode)
        {
            int code = child.ExitCode; Append("Exit code: " + code);
            status.Text = code == 0 ? mode + " complete. Reports are ready."
                : code == 3010 ? "Action needed. Open Reports."
                : log.Text.IndexOf("PSSecurityException", StringComparison.OrdinalIgnoreCase) >= 0 || log.Text.IndexOf("UnauthorizedAccess", StringComparison.OrdinalIgnoreCase) >= 0
                    ? "Execution blocked. Check organization policy in Details."
                    : "Check failed. Open Reports or Details.";
            child.Dispose(); running = null;
            if (logFile != null) { logFile.Dispose(); logFile = null; }
            reports.Enabled = Directory.Exists(output); Busy(false);
        }
    }
}
