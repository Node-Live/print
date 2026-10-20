using Microsoft.AspNetCore.Builder;
using Microsoft.UI.Xaml;
using NodePrint.Core;
using NodePrint.Printing;

namespace NodePrint.App;

public partial class App : Application
{
    private static readonly TimeSpan PortRetry = TimeSpan.FromSeconds(5);

    // Which of the two windows to show while the user compares them: --style native or --style design (the default).
    private readonly bool native = StyleArgument() == "native";
    private readonly CancellationTokenSource quitting = new();
    private MainWindow? designWindow;
    private NativeWindow? nativeWindow;
    private TrayIcon? tray;
    private WebApplication? server;
    private volatile bool portInUse;

    public App()
    {
        if (!native) RequestedTheme = ApplicationTheme.Light;
        InitializeComponent();
        UnhandledException += (_, e) => ErrorLog.Write(e.Exception);
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        var service = await Task.Run(() => PrintService.Open(new WindowsPrintBackend(), new ConfigStore(ConfigStore.DefaultPath)));
        LaunchAtLogin.Apply(service.LaunchAtLogin);

        Windows.Win32.Foundation.HWND handle;
        if (native)
        {
            nativeWindow = new NativeWindow(service, () => portInUse);
            handle = nativeWindow.Handle;
        }
        else
        {
            designWindow = new MainWindow(service, () => portInUse);
            handle = designWindow.Handle;
        }
        tray = new TrayIcon(handle, () => service.LaunchAtLogin);
        tray.OpenRequested += BringToFront;
        tray.LaunchAtLoginToggled += () =>
        {
            service.LaunchAtLogin = !service.LaunchAtLogin;
            LaunchAtLogin.Apply(service.LaunchAtLogin);
        };
        tray.QuitRequested += Quit;

        _ = ServeAsync(service);
        if (!Environment.GetCommandLineArgs().Contains(LaunchAtLogin.TrayArgument)) BringToFront();
    }

    public void BringToFront()
    {
        designWindow?.ShowAndActivate();
        nativeWindow?.ShowAndActivate();
    }

    /// <summary>Starts the local server, and while something else holds the port keeps the window saying so and
    /// tries again every few seconds.</summary>
    private async Task ServeAsync(PrintService service)
    {
        for (bool logged = false; !quitting.IsCancellationRequested;)
        {
            var candidate = LocalApi.Create(service);
            try
            {
                await candidate.StartAsync(quitting.Token);
                server = candidate;
                portInUse = false;
                return;
            }
            catch (IOException e)
            {
                portInUse = true;
                if (!logged) ErrorLog.Write(e);
                logged = true;
                await candidate.DisposeAsync();
            }
            try
            {
                await Task.Delay(PortRetry, quitting.Token);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    private async void Quit()
    {
        quitting.Cancel();
        tray?.Dispose();
        if (server is not null) await server.StopAsync();
        designWindow?.CloseForQuit();
        nativeWindow?.CloseForQuit();
        Exit();
    }

    private static string? StyleArgument()
    {
        var args = Environment.GetCommandLineArgs();
        int at = Array.IndexOf(args, "--style");
        return at >= 0 && at + 1 < args.Length ? args[at + 1] : null;
    }
}
