using System;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace TinnosDebloat
{
    // Standalone GUI-subsystem fixture, no elevation manifest or provisioning.
    internal static class StartupProbe
    {
        [DllImport("kernel32.dll")] private static extern bool FreeConsole();
        [DllImport("kernel32.dll")] private static extern bool SetStdHandle(int kind, IntPtr handle);
        [STAThread]
        private static int Main(string[] args)
        {
            string evidence = args[0];
            try {
                FreeConsole(); SetStdHandle(-11, IntPtr.Zero); SetStdHandle(-12, IntPtr.Zero);
                bool shown = false, failed = false;
                bool failFixture = args.Length > 1;
                int result = Startup.RunGui(delegate {
                    if (failFixture) throw new InvalidDataException("Startup failure fixture");
                    Form form = Ui.Create();
                    form.ShowInTaskbar = false; form.Opacity = 0;
                    form.StartPosition = FormStartPosition.Manual; form.Location = new Point(-32000, -32000);
                    form.Shown += delegate {
                        shown = form.Visible && form.IsHandleCreated && form.WindowState == FormWindowState.Normal;
                        form.BeginInvoke(new Action(delegate { form.Close(); }));
                    };
                    return form;
                }, delegate(Exception error) { failed = error.Message == "Startup failure fixture"; });
                bool pass = failFixture ? result == 1 && failed : result == 0 && shown && !failed;
                File.WriteAllText(evidence, pass ? "PASS" : "FAIL");
                return pass ? 0 : 1;
            } catch (Exception error) { File.WriteAllText(evidence, error.ToString()); return 1; }
        }
    }
}
