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
[assembly: AssemblyVersion("2.6.0.0")]

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

    internal sealed class MainForm : Form
    {
        private static readonly Color Background = Color.FromArgb(17, 23, 27);
        private static readonly Color Surface = Color.FromArgb(29, 39, 43);
        private static readonly Color Accent = Color.FromArgb(245, 195, 58);
        private readonly CheckedListBox equipment = new CheckedListBox { Name = "installList", Dock = DockStyle.Fill,
            CheckOnClick = true, HorizontalScrollbar = true, BackColor = Surface, ForeColor = Color.Gainsboro, BorderStyle = BorderStyle.None };
        private readonly Button start = ActionButton("Start");
        private readonly Button details = ActionButton("Details");
        private readonly TextBox log = new TextBox { Name = "liveLog", Multiline = true, ReadOnly = true, Dock = DockStyle.Fill, ScrollBars = ScrollBars.Both,
            WordWrap = false, BackColor = Surface, ForeColor = Color.Gainsboro, BorderStyle = BorderStyle.None };
        private readonly TextBox errors = new TextBox { Name = "errorDetails", Multiline = true, ReadOnly = true, Dock = DockStyle.Fill, ScrollBars = ScrollBars.Vertical,
            WordWrap = true, BackColor = Surface, ForeColor = Color.Gainsboro, BorderStyle = BorderStyle.None };
        private readonly CheckedListBox cleanup = new CheckedListBox { Name = "removalList", Dock = DockStyle.Fill, Height = 190,
            CheckOnClick = true, HorizontalScrollbar = true, BackColor = Surface, ForeColor = Color.Gainsboro, BorderStyle = BorderStyle.None };
        private readonly ComboBox deviceType = new ComboBox { Name = "deviceType", DropDownStyle = ComboBoxStyle.DropDownList, Width = 125 };
        private readonly ComboBox manufacturer = new ComboBox { Name = "manufacturer", DropDownStyle = ComboBoxStyle.DropDownList, Width = 150 };
        private readonly Dictionary<string, bool> cleanupSelection = new Dictionary<string, bool>();
        private readonly List<CleanupItem> cleanupItems = new List<CleanupItem>();
        private readonly HashSet<string> displayedIssues = new HashSet<string>();
        private readonly TabControl detailTabs = new TabControl { Name = "detailTabs", Dock = DockStyle.Fill, Visible = false };
        private readonly Label status = new Label { Name = "currentTask", Text = "Ready - select actions, then Start.", Dock = DockStyle.Fill, Height = 42, ForeColor = Color.Gainsboro, Margin = new Padding(0, 10, 0, 8) };
        private readonly ProgressBar progress = new ProgressBar { Dock = DockStyle.Fill, Height = 4 };
        private Process running;
        private string directory, output;
        private bool receivedResult;
        private string primaryCode = "";
        private sealed class CleanupItem {
            public string Id, Label, Vendor; public bool DefaultSelected;
            public override string ToString() { return Label; }
        }

        public MainForm()
        {
            Text = "TinnosDebloat-Win11"; BackColor = Background; ForeColor = Color.White;
            Font = new Font("Segoe UI", 10); ClientSize = new Size(1100, 700); MinimumSize = new Size(1000, 680);
            using (Stream icon = Assembly.GetExecutingAssembly().GetManifestResourceStream("Brand.app.ico")) Icon = new Icon(icon);
            StartPosition = FormStartPosition.CenterScreen;
            TableLayoutPanel layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(22), ColumnCount = 1, RowCount = 6 };
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 100));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 420));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 5));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            TableLayoutPanel header = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Margin = Padding.Empty };
            header.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 88)); header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            PictureBox emblem = new PictureBox { Name = "brandEmblem", SizeMode = PictureBoxSizeMode.Zoom, Dock = DockStyle.Fill, Margin = new Padding(0, 0, 16, 12) };
            using (Stream image = Assembly.GetExecutingAssembly().GetManifestResourceStream("Brand.emblem.png")) emblem.Image = new Bitmap(image);
            header.Controls.Add(emblem);
            FlowLayoutPanel heading = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false };
            heading.Controls.Add(new Label { Text = "TINNOS / DEBLOAT", AutoSize = true, Font = new Font("Segoe UI Semibold", 22), ForeColor = Accent });
            heading.Controls.Add(CreateHelpButton("selectionHelp", "How selections work", "Checked = execute the action. Unchecked = leave unchanged. Review your selections, then click Start. Details shows the live log and any errors."));
            header.Controls.Add(heading); layout.Controls.Add(header);
            equipment.Items.Add(new CleanupItem { Id = "GoogleDrive", Label = "Install Google Drive" }, true);
            equipment.Items.Add(new CleanupItem { Id = "Office", Label = "Install Microsoft 365 Office" }, true);
            equipment.Items.Add(new CleanupItem { Id = "Chrome", Label = "Install Google Chrome" }, true);
            TableLayoutPanel choices = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Margin = Padding.Empty };
            choices.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 36)); choices.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 64));
            choices.Controls.Add(ActionSection("EQUIP GEAR", equipment, "Office: PT-BR, 64-bit. Word, Excel, PowerPoint. Teams, OneNote, OneDrive, Access and Outlook excluded."));
            deviceType.Items.AddRange(new object[] { "Desktop", "Laptop" });
            manufacturer.Items.AddRange(new object[] { "Other / None", "ASUS", "Dell" });
            deviceType.SelectedIndex = 0; manufacturer.SelectedIndex = 0; manufacturer.Enabled = false;
            TableLayoutPanel wasps = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1, Margin = Padding.Empty };
            wasps.RowStyles.Add(new RowStyle(SizeType.Absolute, 48)); wasps.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            wasps.Controls.Add(Row(new Label { Text = "Device", AutoSize = true, Padding = new Padding(0, 5, 5, 0) }, deviceType,
                new Label { Text = "Brand", AutoSize = true, Padding = new Padding(10, 5, 5, 0) }, manufacturer));
            wasps.Controls.Add(cleanup);
            choices.Controls.Add(ActionSection("REMOVE WASPS", wasps, "Uninstall removes an app. Deactivate stops and disables a service. Windows may require sign-out or restart.\n\nDesktop excludes ASUS and Dell utilities. For a laptop, choose its brand to select matching utilities. Review these before Start: some affect battery settings or recovery. Armoury Crate requires ASUS's official uninstall tool.\n\nFull Search UI blocking requires updated Windows 11 Pro or higher and a restart. Indexing is a separate action."));
            layout.Controls.Add(choices);
            using (Stream data = Assembly.GetExecutingAssembly().GetManifestResourceStream("Payload.debloat-catalog.json"))
            using (StreamReader reader = new StreamReader(data)) {
                foreach (object entry in (object[])ResultChannel.Serializer().DeserializeObject(reader.ReadToEnd())) {
                    Dictionary<string, object> item = (Dictionary<string, object>)entry;
                    CleanupItem choice = new CleanupItem { Id = TextValue(item, "Id"), Label = TextValue(item, "Name"), Vendor = TextValue(item, "Vendor"), DefaultSelected = !(Value(item, "DefaultSelected") is bool) || (bool)Value(item, "DefaultSelected") };
                    cleanupItems.Add(choice); cleanupSelection[choice.Id] = choice.Vendor == "Dell" || choice.Vendor == "ASUS" || choice.DefaultSelected;
                }
            }
            RefreshCleanup();
            deviceType.SelectedIndexChanged += delegate { manufacturer.Enabled = deviceType.SelectedIndex == 1; RefreshCleanup(); };
            manufacturer.SelectedIndexChanged += delegate { RefreshCleanup(); };
            start.Width = 300; details.Width = 140; details.Name = "detailsButton"; start.Name = "startButton";
            layout.Controls.Add(ActionRow(details, start));
            layout.Controls.Add(status); layout.Controls.Add(progress);
            foreach (string name in new string[] { "Log", "Errors" })
                detailTabs.TabPages.Add(new TabPage(name) { BackColor = Surface, Padding = new Padding(8) });
            detailTabs.TabPages[0].Controls.Add(log); detailTabs.TabPages[1].Controls.Add(errors);
            layout.Controls.Add(detailTabs); Controls.Add(layout);
            start.BackColor = Accent; start.ForeColor = Background;
            details.FlatAppearance.BorderColor = Color.FromArgb(75, 88, 100);
            start.Click += delegate { Run(); };
            details.Click += delegate { SetDetails(!detailTabs.Visible); };
            FormClosing += delegate(object sender, FormClosingEventArgs e) {
                if (running != null) { e.Cancel = true; status.Text = "An operation is running. Wait for the result."; }
            };
        }
        private void RefreshCleanup()
        {
            for (int i = 0; i < cleanup.Items.Count; i++) {
                CleanupItem item = (CleanupItem)cleanup.Items[i]; cleanupSelection[item.Id] = cleanup.GetItemChecked(i);
            }
            cleanup.BeginUpdate(); cleanup.Items.Clear();
            string vendor = deviceType.SelectedIndex == 1 ? Convert.ToString(manufacturer.SelectedItem) : "";
            foreach (CleanupItem item in cleanupItems) {
                bool oem = item.Vendor == "Dell" || item.Vendor == "ASUS";
                if (oem && item.Vendor != vendor) continue;
                cleanup.Items.Add(item, cleanupSelection[item.Id]);
            }
            cleanup.EndUpdate();
        }
        private void SetDetails(bool show)
        {
            detailTabs.Visible = show;
            int availableHeight = Screen.FromControl(this).WorkingArea.Height - SystemInformation.CaptionHeight - 32;
            ClientSize = new Size(ClientSize.Width, Math.Min(availableHeight, show ? 940 : 700));
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
        private static Button CreateHelpButton(string name, string title, string guidance)
        {
            Button button = ActionButton("?");
            button.Name = name; button.AccessibleName = title + " help";
            button.AccessibleDescription = guidance;
            button.Size = new Size(28, 28); button.Margin = new Padding(0, 0, 0, 8);
            button.Font = new Font("Segoe UI", 10, FontStyle.Bold);
            button.ForeColor = Accent; button.FlatAppearance.BorderSize = 0;
            button.FlatAppearance.MouseOverBackColor = Color.FromArgb(49, 63, 67);
            button.Click += delegate { MessageBox.Show(button.FindForm(), guidance, title,
                MessageBoxButtons.OK, MessageBoxIcon.Information); };
            return button;
        }
        private static Control ActionSection(string title, Control content, string note)
        {
            TableLayoutPanel card = new TableLayoutPanel { Dock = DockStyle.Fill, BackColor = Surface,
                Padding = new Padding(12), Margin = new Padding(0, 0, 10, 12), ColumnCount = 1, RowCount = 2 };
            card.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
            card.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            TableLayoutPanel heading = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Margin = Padding.Empty };
            heading.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            heading.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 30));
            heading.Controls.Add(new Label { Text = title, AutoSize = true, ForeColor = Color.FromArgb(167, 181, 194),
                Font = new Font("Segoe UI", 10f, FontStyle.Bold), Margin = new Padding(0, 4, 0, 0) });
            if (note != null) heading.Controls.Add(CreateHelpButton(title == "EQUIP GEAR" ? "gearHelp" : "waspsHelp", title, note));
            card.Controls.Add(heading); card.Controls.Add(content);
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
            foreach (Control item in new Control[] { equipment, cleanup, start, deviceType, manufacturer }) item.Enabled = !busy;
            manufacturer.Enabled = !busy && deviceType.SelectedIndex == 1;
            progress.Style = busy ? ProgressBarStyle.Marquee : ProgressBarStyle.Blocks;
        }
        public string SelectedConfiguration()
        {
            List<string> install = new List<string>(), remove = new List<string>();
            foreach (CleanupItem item in equipment.CheckedItems) install.Add(item.Id);
            foreach (CleanupItem item in cleanup.CheckedItems) remove.Add(item.Id);
            return ResultChannel.Serializer().Serialize(new Dictionary<string, object> {
                { "LicenseEdition", "Business" }, { "Architecture", "64" }, { "Languages", new string[] { "pt-br" } }, { "Channel", "Current" },
                { "InstallItems", install.ToArray() }, { "RemoveItems", remove.ToArray() }
            });
        }
        private void Run()
        {
            if (running != null) return;
            try
            {
                if (equipment.CheckedItems.Count == 0 && cleanup.CheckedItems.Count == 0) {
                    status.Text = "Nothing selected. Mark the actions you want to execute.";
                    Append(status.Text); return;
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
