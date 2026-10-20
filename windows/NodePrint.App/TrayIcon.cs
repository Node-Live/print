using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.Shell;
using Windows.Win32.UI.WindowsAndMessaging;

namespace NodePrint.App;

/// <summary>The notification-area icon with its Open / Launch at login / Quit menu.</summary>
internal sealed unsafe class TrayIcon : IDisposable
{
    private const uint CallbackMessage = PInvoke.WM_APP + 1;
    private const uint OpenCommand = 1;
    private const uint LaunchAtLoginCommand = 2;
    private const uint QuitCommand = 3;
    private const uint TrackReturnCommand = 0x0100;
    private const uint TrackRightButton = 0x0002;

    private readonly HWND window;
    private readonly Func<bool> launchAtLogin;
    private readonly uint taskbarCreated;
    private HICON icon;
    private bool disposed;

    public TrayIcon(HWND window, Func<bool> launchAtLogin)
    {
        this.window = window;
        this.launchAtLogin = launchAtLogin;
        taskbarCreated = PInvoke.RegisterWindowMessage("TaskbarCreated");
        uint dpi = PInvoke.GetDpiForWindow(window);
        int size = PInvoke.GetSystemMetricsForDpi(SYSTEM_METRICS_INDEX.SM_CXSMICON, dpi);
        fixed (char* path = Path.Combine(AppContext.BaseDirectory, "Assets", "NodePrint.ico"))
        {
            icon = (HICON)(nint)PInvoke.LoadImage(default, path, GDI_IMAGE_TYPE.IMAGE_ICON, size, size, IMAGE_FLAGS.LR_LOADFROMFILE).Value;
        }
        WindowChrome.AddHook(OnMessage);
        Add();
    }

    public event Action? OpenRequested;
    public event Action? LaunchAtLoginToggled;
    public event Action? QuitRequested;

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        var data = Data();
        PInvoke.Shell_NotifyIcon(NOTIFY_ICON_MESSAGE.NIM_DELETE, &data);
        PInvoke.DestroyIcon(icon);
    }

    private NOTIFYICONDATAW Data() => new()
    {
        cbSize = (uint)sizeof(NOTIFYICONDATAW),
        hWnd = window,
        uID = 1,
    };

    private void Add()
    {
        var data = Data();
        data.uFlags = NOTIFY_ICON_DATA_FLAGS.NIF_MESSAGE | NOTIFY_ICON_DATA_FLAGS.NIF_ICON | NOTIFY_ICON_DATA_FLAGS.NIF_TIP |
            NOTIFY_ICON_DATA_FLAGS.NIF_SHOWTIP;
        data.uCallbackMessage = CallbackMessage;
        data.hIcon = icon;
        data.szTip = "NODE Print";
        PInvoke.Shell_NotifyIcon(NOTIFY_ICON_MESSAGE.NIM_ADD, &data);
        data.uVersion = PInvoke.NOTIFYICON_VERSION_4;
        PInvoke.Shell_NotifyIcon(NOTIFY_ICON_MESSAGE.NIM_SETVERSION, &data);
    }

    private bool OnMessage(uint message, WPARAM wParam, LPARAM lParam)
    {
        if (disposed) return false;
        if (message == taskbarCreated)
        {
            // Explorer restarted and forgot every icon.
            Add();
            return false;
        }
        if (message != CallbackMessage) return false;
        switch ((uint)(lParam.Value & 0xFFFF))
        {
            case PInvoke.NIN_SELECT:
            case PInvoke.NIN_SELECT | 1:
                OpenRequested?.Invoke();
                break;
            case PInvoke.WM_CONTEXTMENU:
                ShowMenu((short)(wParam.Value & 0xFFFF), (short)((wParam.Value >> 16) & 0xFFFF));
                break;
        }
        return true;
    }

    private void ShowMenu(int x, int y)
    {
        var menu = PInvoke.CreatePopupMenu();
        try
        {
            Append(menu, MENU_ITEM_FLAGS.MF_STRING, OpenCommand, Strings.Get("TrayOpen"));
            Append(menu, launchAtLogin() ? MENU_ITEM_FLAGS.MF_STRING | MENU_ITEM_FLAGS.MF_CHECKED : MENU_ITEM_FLAGS.MF_STRING,
                LaunchAtLoginCommand, Strings.Get("TrayLaunchAtLogin"));
            PInvoke.AppendMenu(menu, MENU_ITEM_FLAGS.MF_SEPARATOR, 0, default);
            Append(menu, MENU_ITEM_FLAGS.MF_STRING, QuitCommand, Strings.Get("TrayQuit"));

            // Without the foreground the menu would not close when the user clicks elsewhere.
            PInvoke.SetForegroundWindow(window);
            uint command = (uint)PInvoke.TrackPopupMenuEx(menu, TrackReturnCommand | TrackRightButton, x, y, window, null).Value;
            PInvoke.PostMessage(window, PInvoke.WM_NULL, 0, 0);
            switch (command)
            {
                case OpenCommand: OpenRequested?.Invoke(); break;
                case LaunchAtLoginCommand: LaunchAtLoginToggled?.Invoke(); break;
                case QuitCommand: QuitRequested?.Invoke(); break;
            }
        }
        finally
        {
            PInvoke.DestroyMenu(menu);
        }
    }

    private static void Append(HMENU menu, MENU_ITEM_FLAGS flags, uint command, string text)
    {
        fixed (char* label = text)
        {
            PInvoke.AppendMenu(menu, flags, command, label);
        }
    }
}
