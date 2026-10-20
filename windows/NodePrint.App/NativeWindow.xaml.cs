using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using NodePrint.Core;
using Windows.Graphics;
using Windows.Win32;
using Windows.Win32.Foundation;

namespace NodePrint.App;

/// <summary>The same window with nothing but WinUI's own controls and styles, for comparing with the designed one.</summary>
public sealed partial class NativeWindow : Window
{
    private const int ContentWidth = 520;
    private const int ContentHeight = 430;

    private readonly PrintService service;
    private readonly Func<bool> portInUse;
    private readonly DispatcherQueueTimer refreshTimer;
    private bool quitting;

    public NativeWindow(PrintService service, Func<bool> portInUse)
    {
        this.service = service;
        this.portInUse = portInUse;
        InitializeComponent();
        Handle = new HWND(WinRT.Interop.WindowNative.GetWindowHandle(this));
        Title = "NODE Print";
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "NodePrint.ico"));
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
        }
        WindowChrome.Attach(Handle);

        PortBar.Title = Strings.Get("PortInUse");
        VersionText.Text = string.Format(Strings.Get("Version"), AppInfo.Version);
        LabelChannel.Setup(Channel.Label, service);
        DocumentChannel.Setup(Channel.Document, service);

        AppWindow.Closing += (_, args) =>
        {
            if (quitting) return;
            args.Cancel = true;
            AppWindow.Hide();
        };
        refreshTimer = DispatcherQueue.CreateTimer();
        refreshTimer.Interval = TimeSpan.FromSeconds(2);
        refreshTimer.Tick += (_, _) =>
        {
            if (AppWindow.IsVisible) Refresh();
        };
        refreshTimer.Start();

        double scale = PInvoke.GetDpiForWindow(Handle) / 96.0;
        AppWindow.ResizeClient(new SizeInt32((int)Math.Round(ContentWidth * scale), (int)Math.Round(ContentHeight * scale)));
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Move(new PointInt32(area.X + (area.Width - AppWindow.Size.Width) / 2, area.Y + (area.Height - AppWindow.Size.Height) / 2));
        Refresh();
    }

    internal HWND Handle { get; }

    public void ShowAndActivate()
    {
        AppWindow.Show();
        Activate();
        PInvoke.SetForegroundWindow(Handle);
        Refresh();
    }

    public void CloseForQuit()
    {
        quitting = true;
        refreshTimer.Stop();
        Close();
    }

    private async void Refresh()
    {
        try
        {
            var (printers, label, document) = await Task.Run(() =>
                (service.Printers(), service.ChannelStatus(Channel.Label), service.ChannelStatus(Channel.Document)));
            LabelChannel.Show(printers, label);
            DocumentChannel.Show(printers, document);
            PortBar.IsOpen = portInUse();
        }
        catch (Exception e)
        {
            ErrorLog.Write(e);
        }
    }
}
