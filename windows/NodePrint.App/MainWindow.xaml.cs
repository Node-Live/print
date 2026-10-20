using Microsoft.UI;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Media;
using NodePrint.Core;
using Windows.Graphics;
using Windows.Win32;
using Windows.Win32.Foundation;

namespace NodePrint.App;

public sealed partial class MainWindow : Window
{
    private const int ContentWidth = 520;
    private const int ContentHeight = 372;

    private readonly PrintService service;
    private readonly DispatcherQueueTimer refreshTimer;
    private bool quitting;

    public MainWindow(PrintService service)
    {
        this.service = service;
        InitializeComponent();
        Handle = new HWND(WinRT.Interop.WindowNative.GetWindowHandle(this));
        Title = "NODE Print";
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "NodePrint.ico"));
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
        }
        // The top of the window is ours: no system caption buttons, the strip around the pill drags the window.
        AppWindow.TitleBar.ExtendsContentIntoTitleBar = true;
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Collapsed;
        WindowChrome.Attach(Handle);

        // Mica shows through a light veil so the cards keep the design's contrast; without Mica the window is white.
        bool mica = MicaController.IsSupported();
        if (mica) SystemBackdrop = new MicaBackdrop();
        Root.Background = new SolidColorBrush(mica ? ColorHelper.FromArgb(0xCC, 0xFF, 0xFF, 0xFF) : Colors.White);

        VersionText.Text = "v" + AppInfo.Version;
        ToolTipService.SetToolTip(MinimizeButton, Strings.Get("Minimize"));
        ToolTipService.SetToolTip(CloseButton, Strings.Get("Close"));
        LabelSection.Setup(Channel.Label, service);
        DocumentSection.Setup(Channel.Document, service);
        LabelSection.Chosen += Refresh;
        DocumentSection.Chosen += Refresh;
        Root.Loaded += (_, _) =>
        {
            // The client area only reaches the top edge once the extended title bar is in effect, so size it now.
            PlaceOnScreen();
            Shadows.Attach(PillShadow, PillShape, blur: 22, offsetY: 4, opacity: 0.11f);
            SetDragRegion();
            Root.XamlRoot.Changed += (_, _) => SetDragRegion();
        };

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

        PlaceOnScreen();
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
            var (label, document) = await Task.Run(() =>
                (service.ChannelStatus(Channel.Label), service.ChannelStatus(Channel.Document)));
            LabelSection.Show(label);
            DocumentSection.Show(document);
        }
        catch (Exception e)
        {
            // The spooler can fail a query now and then; the next tick tries again.
            ErrorLog.Write(e);
        }
    }

    private void PlaceOnScreen()
    {
        double scale = WindowChrome.Scale(Handle);
        AppWindow.ResizeClient(new SizeInt32((int)Math.Round(ContentWidth * scale), (int)Math.Round(ContentHeight * scale)));
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Move(new PointInt32(
            area.X + (area.Width - AppWindow.Size.Width) / 2,
            area.Y + (area.Height - AppWindow.Size.Height) / 2));
    }

    private void SetDragRegion()
    {
        double scale = Root.XamlRoot.RasterizationScale;
        var captionButtons = MinimizeButton.ActualWidth + CloseButton.ActualWidth;
        InputNonClientPointerSource.GetForWindowId(AppWindow.Id).SetRegionRects(NonClientRegionKind.Caption,
        [
            new RectInt32(0, 0, (int)Math.Round((ContentWidth - captionButtons) * scale), (int)Math.Round(DragStrip.ActualHeight * scale)),
        ]);
    }

    private void OnMinimize(object sender, RoutedEventArgs e)
    {
        if (AppWindow.Presenter is OverlappedPresenter presenter) presenter.Minimize();
    }

    private void OnClose(object sender, RoutedEventArgs e) => AppWindow.Hide();
}
