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
[assembly: AssemblyVersion("2.2.0.0")]

namespace TinnosDebloat
{
    public static class Payload
    {
        public static readonly string[] Files = { "Invoke-Provisioning.ps1", "Invoke-UserCleanup.ps1", "Provisioning.psm1", "Check-OfficeActivation.ps1", "config.example.json", "error-codes.json" };
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
            CultureInfo english = CultureInfo.GetCultureInfo("en-US");
            CultureInfo.DefaultThreadCurrentCulture = english; CultureInfo.DefaultThreadCurrentUICulture = english;
            Thread.CurrentThread.CurrentCulture = english; Thread.CurrentThread.CurrentUICulture = english;
            Console.OutputEncoding = new UTF8Encoding(false);
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

    public static class Ui
    {
        public static Form Create() { return new MainForm(); }
    }

    internal sealed class MainForm : Form
    {
        private static readonly Color Background = Color.FromArgb(23, 29, 35);
        private static readonly Color Surface = Color.FromArgb(38, 46, 54);
        private static readonly Color Accent = Color.FromArgb(218, 180, 103);
        private readonly RadioButton downloadOnly = ModeButton("Download only", true);
        private readonly RadioButton installApps = ModeButton("Download + install", false);
        private readonly CheckBox access = Toggle("Include Access", false);
        private readonly CheckBox oneDrive = Toggle("Exclude OneDrive", true);
        private readonly CheckBox outlook = Toggle("Exclude new Outlook", true);
        private readonly Button start = ActionButton("Start");
        private readonly Button details = ActionButton("Details");
        private readonly TextBox log = new TextBox { Multiline = true, ReadOnly = true, Dock = DockStyle.Fill, ScrollBars = ScrollBars.Both,
            WordWrap = false, BackColor = Surface, ForeColor = Color.Gainsboro, BorderStyle = BorderStyle.None };
        private readonly TextBox errors = new TextBox { Name = "errorDetails", Multiline = true, ReadOnly = true, Dock = DockStyle.Fill, ScrollBars = ScrollBars.Vertical,
            WordWrap = true, BackColor = Surface, ForeColor = Color.Gainsboro, BorderStyle = BorderStyle.None };
        private readonly ListView results = new ListView { Name = "resultList", Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true,
            BackColor = Surface, ForeColor = Color.Gainsboro, BorderStyle = BorderStyle.None, ShowItemToolTips = true };
        private readonly TabControl detailTabs = new TabControl { Name = "detailTabs", Dock = DockStyle.Fill, Visible = false };
        private readonly Label status = new Label { Text = "Ready — Office PT-BR", AutoSize = true, ForeColor = Color.Gainsboro, Margin = new Padding(0, 10, 0, 8) };
        private readonly ProgressBar progress = new ProgressBar { Dock = DockStyle.Fill, Height = 4 };
        private Process running;
        private string directory, output;
        private bool receivedResult;
        private string primaryCode = "";

        public MainForm()
        {
            Text = "TinnosDebloat-Win11"; BackColor = Background; ForeColor = Color.White;
            Font = new Font("Segoe UI", 10); ClientSize = new Size(680, 370); MinimumSize = new Size(696, 409);
            StartPosition = FormStartPosition.CenterScreen;
            TableLayoutPanel layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(22), ColumnCount = 1, RowCount = 6 };
            for (int i = 0; i < 4; i++) layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 5));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            layout.Controls.Add(Section("APP ACTION", Row(downloadOnly, installApps), "Restore point and Teams cleanup are always included."));
            layout.Controls.Add(Section("OFFICE OPTIONS", Row(access, oneDrive, outlook), "Microsoft 365 Apps for Business · PT-BR · 64-bit"));
            start.Width = 300; details.Width = 140; details.Name = "detailsButton"; start.Name = "startButton";
            layout.Controls.Add(ActionRow(details, start));
            layout.Controls.Add(status); layout.Controls.Add(progress);
            results.Columns.Add("Component", 220); results.Columns.Add("Result", 130); results.Columns.Add("Code", 110); results.Columns.Add("Details", 260);
            foreach (string name in new string[] { "Results", "Errors", "Log" })
                detailTabs.TabPages.Add(new TabPage(name) { BackColor = Surface, Padding = new Padding(8) });
            detailTabs.TabPages[0].Controls.Add(results); detailTabs.TabPages[1].Controls.Add(errors); detailTabs.TabPages[2].Controls.Add(log);
            layout.Controls.Add(detailTabs); Controls.Add(layout);
            start.BackColor = Accent; start.ForeColor = Background;
            details.FlatAppearance.BorderColor = Color.FromArgb(75, 88, 100);
            start.Click += delegate { Run(); };
            details.Click += delegate { SetDetails(!detailTabs.Visible); };
            FormClosing += delegate(object sender, FormClosingEventArgs e) {
                if (running != null) { e.Cancel = true; status.Text = "An operation is running. Wait for the result."; }
            };
        }
        private static CheckBox Toggle(string text, bool selected)
        {
            CheckBox button = new CheckBox { Text = text, Checked = selected, Appearance = Appearance.Button, AutoSize = false,
                Width = 196, Height = 38,
                TextAlign = ContentAlignment.MiddleCenter, FlatStyle = FlatStyle.Flat, Padding = Padding.Empty, Margin = new Padding(0, 0, 8, 0) };
            button.FlatAppearance.BorderColor = Accent;
            Action recolor = delegate { button.BackColor = button.Checked ? Accent : Surface; button.ForeColor = button.Checked ? Background : Color.Gainsboro; };
            button.CheckedChanged += delegate { recolor(); }; recolor(); return button;
        }
        private static RadioButton ModeButton(string text, bool selected)
        {
            RadioButton button = new RadioButton { Text = text, Checked = selected, Appearance = Appearance.Button,
                Width = 298, Height = 38, TextAlign = ContentAlignment.MiddleCenter, FlatStyle = FlatStyle.Flat,
                Margin = new Padding(0, 0, 8, 0), TabStop = selected };
            button.FlatAppearance.BorderColor = Accent;
            Action recolor = delegate { button.BackColor = button.Checked ? Accent : Background; button.ForeColor = button.Checked ? Background : Color.Gainsboro; };
            button.CheckedChanged += delegate { recolor(); }; recolor(); return button;
        }
        private void SetDetails(bool show)
        {
            detailTabs.Visible = show;
            int availableHeight = Screen.FromControl(this).WorkingArea.Height - SystemInformation.CaptionHeight - 32;
            ClientSize = new Size(ClientSize.Width, show ? Math.Max(370, Math.Min(720, availableHeight)) : 370);
        }
        private static Button ActionButton(string text)
        {
            Button button = new Button { Text = text, FlatStyle = FlatStyle.Flat, Width = 124, Height = 38,
                BackColor = Surface, ForeColor = Color.Gainsboro, Margin = Padding.Empty };
            button.FlatAppearance.BorderColor = Accent; return button;
        }
        private static FlowLayoutPanel Row(params Control[] controls)
        {
            FlowLayoutPanel panel = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, WrapContents = false, Margin = Padding.Empty };
            panel.Controls.AddRange(controls); return panel;
        }
        private static Control Section(string title, Control content, string note)
        {
            TableLayoutPanel card = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, BackColor = Surface,
                Padding = new Padding(12), Margin = new Padding(0, 0, 0, 12), ColumnCount = 1 };
            card.Controls.Add(new Label { Text = title, AutoSize = true, ForeColor = Color.FromArgb(167, 181, 194),
                Font = new Font("Segoe UI", 8.5f, FontStyle.Bold), Margin = new Padding(0, 0, 0, 8) });
            card.Controls.Add(content);
            if (note != null) card.Controls.Add(new Label { Text = note, AutoSize = true, ForeColor = Color.FromArgb(167, 181, 194),
                Font = new Font("Segoe UI", 8.5f), Margin = new Padding(0, 8, 0, 0) });
            return card;
        }
        private static Control ActionRow(Control left, Control right)
        {
            TableLayoutPanel row = new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, ColumnCount = 2, Margin = new Padding(0, 4, 0, 4) };
            row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50)); row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            left.Anchor = AnchorStyles.Left; right.Anchor = AnchorStyles.Right;
            row.Controls.Add(left, 0, 0); row.Controls.Add(right, 1, 0); return row;
        }
        private void Append(string text)
        {
            if (text == null || IsDisposed) return;
            if (InvokeRequired) { BeginInvoke(new Action<string>(Append), text); return; }
            if (text.StartsWith(ResultChannel.Prefix, StringComparison.Ordinal)) {
                try { ApplyResult(ResultChannel.Decode(text)); }
                catch (Exception error) { DisplayError("TNO-904", error.Message); }
                return;
            }
            log.AppendText(text + Environment.NewLine);
        }
        private void Busy(bool busy)
        {
            foreach (Control item in new Control[] { downloadOnly, installApps, access, oneDrive, outlook, start }) item.Enabled = !busy;
            progress.Style = busy ? ProgressBarStyle.Marquee : ProgressBarStyle.Blocks;
        }
        private void Run()
        {
            if (running != null) return;
            try
            {
                directory = Payload.Extract(); output = Path.Combine(directory, "Work");
                Dictionary<string, object> config = new Dictionary<string, object> {
                    { "LicenseEdition", "Business" }, { "Architecture", "64" }, { "Languages", new string[] { "pt-br" } }, { "Channel", "Current" },
                    { "IncludeAccess", access.Checked }, { "ExcludeOneDrive", oneDrive.Checked }, { "ExcludeNewOutlook", outlook.Checked },
                    { "AppMode", downloadOnly.Checked ? "Download" : "Install" }
                };
                string configPath = Path.Combine(directory, "config.json");
                File.WriteAllText(configPath, new JavaScriptSerializer().Serialize(config), new UTF8Encoding(false));
                receivedResult = false; primaryCode = ""; log.Clear(); errors.Clear(); results.Items.Clear();
                Append("Starting. Results remain in memory. Working files: " + output);
                running = new Process { StartInfo = Payload.Command(directory, configPath, "Deploy", output), EnableRaisingEvents = true };
                running.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) { Append(e.Data); };
                running.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { Append(e.Data); };
                Process child = running;
                child.Exited += delegate { ThreadPool.QueueUserWorkItem(delegate {
                    child.WaitForExit(); BeginInvoke(new Action(delegate { Finish(child); }));
                }); };
                Busy(true); status.Text = "Creating restore point and preparing deployment...";
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
                : code == 2 ? "Cleanup passed; some apps were skipped. View Details."
                : code == 3010 ? "Action needed. View Details." : "Check failed. View Details.");
            child.Dispose(); running = null;
            Busy(false); SetDetails(true);
        }
        private void DisplayError(string code, string message)
        {
            primaryCode = code; errors.AppendText(ResultChannel.ErrorText(code, message) + Environment.NewLine + Environment.NewLine);
            status.Text = "[" + code + "] View Details."; SetDetails(true); detailTabs.SelectedIndex = 1;
        }
        private static object Value(Dictionary<string, object> map, string key)
        {
            object value; return map != null && map.TryGetValue(key, out value) ? value : null;
        }
        private static string TextValue(Dictionary<string, object> map, string key) { return Convert.ToString(Value(map, key)); }
        private static object[] Items(Dictionary<string, object> map, string key) { return Value(map, key) as object[] ?? new object[0]; }
        private void AddResult(string name, string result, string code, string detail)
        {
            ListViewItem row = new ListViewItem(new string[] { name, result, code, detail }); row.ToolTipText = detail; results.Items.Add(row);
        }
        public void ApplyResult(string json)
        {
            Dictionary<string, object> report = ResultChannel.Serializer().DeserializeObject(json) as Dictionary<string, object>;
            if (report == null || Value(report, "Status") == null) throw new InvalidDataException("Worker result has no status.");
            results.Items.Clear(); errors.Clear(); primaryCode = "";
            AddResult("Overall", TextValue(report, "Status"), "", "Results are kept in memory for this session.");
            Dictionary<string, object> restore = Value(report, "RestorePoint") as Dictionary<string, object>;
            if (restore != null) AddResult("Restore point", TextValue(restore, "Status"), "", TextValue(restore, "CreatedUTC"));
            Dictionary<string, object> activation = Value(report, "Activation") as Dictionary<string, object>;
            if (activation != null) AddResult("Office activation", TextValue(activation, "Status"), "", TextValue(activation, "Reason"));
            foreach (object item in Items(report, "Applications")) {
                Dictionary<string, object> app = item as Dictionary<string, object>;
                Dictionary<string, object> detail = Value(app, "Detail") as Dictionary<string, object>;
                AddResult(TextValue(app, "Name"), TextValue(app, "Status"), TextValue(app, "ErrorCode"), TextValue(app, "Error") + TextValue(detail, "Artifact"));
            }
            foreach (object item in Items(report, "Checks")) {
                Dictionary<string, object> check = item as Dictionary<string, object>;
                bool pass = Value(check, "Pass") is bool && (bool)Value(check, "Pass");
                bool required = !(Value(check, "Required") is bool) || (bool)Value(check, "Required");
                object evidence = Value(check, "Detail");
                AddResult(TextValue(check, "Name"), pass ? "Passed" : required ? "Failed" : "Not required", "", evidence == null ? "" : ResultChannel.Serializer().Serialize(evidence));
            }
            foreach (string severity in new string[] { "Error", "Pending", "Warning" })
                foreach (object item in Items(report, "Issues")) {
                    Dictionary<string, object> issue = item as Dictionary<string, object>;
                    if (TextValue(issue, "Severity") != severity) continue;
                    string issueCode = TextValue(issue, "Code"); if (primaryCode == "") primaryCode = issueCode;
                    errors.AppendText("[" + issueCode + "] " + TextValue(issue, "Title") + " (" + severity + ")" + Environment.NewLine
                        + TextValue(issue, "Message") + Environment.NewLine + "Next step: " + TextValue(issue, "Action") + Environment.NewLine
                        + (Value(issue, "NativeCode") == null ? "" : "Native exit code: " + TextValue(issue, "NativeCode") + Environment.NewLine) + Environment.NewLine);
                }
            foreach (object note in Items(report, "Notes")) log.AppendText(Convert.ToString(note) + Environment.NewLine);
            receivedResult = true; SetDetails(true); detailTabs.SelectedIndex = primaryCode == "" ? 0 : 1;
        }
    }
}
