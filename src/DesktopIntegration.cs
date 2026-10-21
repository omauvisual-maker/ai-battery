using System;
using System.Runtime.InteropServices;
namespace AIBattery {
 public static class DesktopIntegration {
  public sealed class WindowState { public bool Visible; public bool Minimized; }
  private delegate bool EnumWindowProc(IntPtr window, IntPtr data);
  [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowProc callback, IntPtr data);
  [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
  [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr window);
  [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr window, uint command);
  public static WindowState[] ReadWindows(int[] processIds) {
   var windows=new System.Collections.Generic.List<WindowState>();
   EnumWindows(delegate(IntPtr window, IntPtr data) {
    uint processId; GetWindowThreadProcessId(window,out processId);
    if (Array.IndexOf(processIds,(int)processId)>=0 && GetWindow(window,4)==IntPtr.Zero && IsWindowVisible(window))
     windows.Add(new WindowState {Visible=true,Minimized=IsIconic(window)});
    return true;
   },IntPtr.Zero);
   return windows.ToArray();
  }
  public const string AppId = "AIBattery.Desktop";
  [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern int SetCurrentProcessExplicitAppUserModelID(string id);
  [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern int SHGetPropertyStoreFromParsingName(string path, IntPtr bind, uint flags, ref Guid iid, out IPropertyStore store);
  [DllImport("shell32.dll")] private static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, out IPropertyStore store);
  [DllImport("ole32.dll")] private static extern int PropVariantClear(ref PropVariant value);
  [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr handle);
  [StructLayout(LayoutKind.Sequential)] private struct PropertyKey { public Guid Format; public uint Id; public PropertyKey(uint id) { Format = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"); Id = id; } }
  [StructLayout(LayoutKind.Explicit, Size=24)] private struct PropVariant { [FieldOffset(0)] public ushort Type; [FieldOffset(8)] public IntPtr Value; }
  [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] private interface IPropertyStore {
   [PreserveSig] int GetCount(out uint count);
   [PreserveSig] int GetAt(uint index, out PropertyKey key);
   [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
   [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
   [PreserveSig] int Commit();
  }
  private static readonly Guid StoreIid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
  private static void Set(IPropertyStore store, uint id, string text) {
   var key = new PropertyKey(id); var value = new PropVariant { Type=31, Value=Marshal.StringToCoTaskMemUni(text) };
   try { Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref value)); } finally { PropVariantClear(ref value); }
  }
  public static void SetProcessIdentity() { Marshal.ThrowExceptionForHR(SetCurrentProcessExplicitAppUserModelID(AppId)); }
  public static void SetShortcutIdentity(string path) {
   IPropertyStore store; Guid iid=StoreIid; Marshal.ThrowExceptionForHR(SHGetPropertyStoreFromParsingName(path, IntPtr.Zero, 2, ref iid, out store));
   try { Set(store,5,AppId);Marshal.ThrowExceptionForHR(store.Commit()); } finally { Marshal.ReleaseComObject(store); }
  }
  public static string GetShortcutIdentity(string path) {
   IPropertyStore store; Guid iid=StoreIid; Marshal.ThrowExceptionForHR(SHGetPropertyStoreFromParsingName(path, IntPtr.Zero, 0, ref iid, out store));
   try { var key=new PropertyKey(5); PropVariant value;Marshal.ThrowExceptionForHR(store.GetValue(ref key,out value));try {return value.Type==31 ? Marshal.PtrToStringUni(value.Value) : null;} finally {PropVariantClear(ref value);} } finally {Marshal.ReleaseComObject(store);}
  }
  public static void SetWindowIdentity(IntPtr hwnd, string launcher, string icon) {
   IPropertyStore store;Guid iid=StoreIid;Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(hwnd,ref iid,out store));
   try {Set(store,5,AppId);Set(store,2,"\""+launcher+"\"");Set(store,3,icon+",0");Set(store,4,"AI Battery");Marshal.ThrowExceptionForHR(store.Commit());} finally {Marshal.ReleaseComObject(store);}
  }
 }
}
