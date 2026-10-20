using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Dwm;
using Windows.Win32.UI.WindowsAndMessaging;

namespace NodePrint.App;

/// <summary>The Win32 side of the main window: its message hooks and rounded corners.</summary>
internal static unsafe class WindowChrome
{
    private static readonly List<Func<uint, WPARAM, LPARAM, bool>> Hooks = [];
    private static System.Drawing.Point fixedSize;

    public static void Attach(HWND window)
    {
        PInvoke.SetWindowSubclass(window, &Procedure, 1, 0);
        var corner = DWM_WINDOW_CORNER_PREFERENCE.DWMWCP_ROUND;
        // Windows 10 has no such attribute; the call just fails there.
        PInvoke.DwmSetWindowAttribute(window, DWMWINDOWATTRIBUTE.DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof(DWM_WINDOW_CORNER_PREFERENCE));
    }

    /// <summary>Holds the window at this outer size: whatever frame the title bar settings bring back, it cannot be
    /// dragged larger or smaller.</summary>
    public static void FixSize(int width, int height) => fixedSize = new System.Drawing.Point(width, height);

    /// <summary>Runs on every message to the window; returning true swallows it.</summary>
    public static void AddHook(Func<uint, WPARAM, LPARAM, bool> hook) => Hooks.Add(hook);

    public static double Scale(HWND window) => PInvoke.GetDpiForWindow(window) / 96.0;

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
    private static LRESULT Procedure(HWND window, uint message, WPARAM wParam, LPARAM lParam, nuint id, nuint data)
    {
        // The window has a fixed size: a double click on the drag strip or a system command must not maximise it.
        if (message == PInvoke.WM_NCLBUTTONDBLCLK ||
            (message == PInvoke.WM_SYSCOMMAND && (wParam.Value & 0xFFF0) == PInvoke.SC_MAXIMIZE))
        {
            return (LRESULT)0;
        }
        if (message == PInvoke.WM_GETMINMAXINFO && fixedSize.X > 0)
        {
            var limits = (MINMAXINFO*)lParam.Value;
            limits->ptMinTrackSize = fixedSize;
            limits->ptMaxTrackSize = fixedSize;
            return (LRESULT)0;
        }
        foreach (var hook in Hooks)
        {
            if (hook(message, wParam, lParam)) return (LRESULT)0;
        }
        return PInvoke.DefSubclassProc(window, message, wParam, lParam);
    }
}
