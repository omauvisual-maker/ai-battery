using System;
using System.Diagnostics;
using System.IO;
using System.Security.Principal;
using System.Threading;
using System.Windows.Forms;
using System.Reflection;
[assembly: AssemblyTitle("AI Battery")]
[assembly: AssemblyProduct("AI Battery")]
[assembly: AssemblyDescription("Painel de consumo de IA")]
[assembly: AssemblyVersion("2.0.0.0")]
internal static class Launcher {
 [STAThread] static int Main() {
  try {
   string sid = WindowsIdentity.GetCurrent().User.Value;
   try { using (var evt = EventWaitHandle.OpenExisting("Local\\AIBattery.Toggle." + sid)) { evt.Set(); return 0; } }
   catch (WaitHandleCannotBeOpenedException) { }
   string root = AppDomain.CurrentDomain.BaseDirectory;
   string script = Path.Combine(root, "Start-AIBattery.ps1");
   if (!File.Exists(script)) throw new FileNotFoundException("Start-AIBattery.ps1 nao encontrado.");
   string exe = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell\\v1.0\\powershell.exe");
   var info = new ProcessStartInfo(exe, "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\" -ShowPanel");
   info.UseShellExecute = false; info.CreateNoWindow = true; info.WindowStyle = ProcessWindowStyle.Hidden; info.WorkingDirectory = root;
   using (var process = Process.Start(info)) { }
   return 0;
  } catch { MessageBox.Show("Nao foi possivel abrir o painel. Verifique a pasta do projeto.", "AI Battery"); return 1; }
 }
}
