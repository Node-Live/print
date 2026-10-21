using Microsoft.AspNetCore.Builder;
using Microsoft.UI.Xaml;
using NodePrint.Core;
using NodePrint.Printing;

namespace NodePrint.App;

public partial class App : Application
{
    private static readonly TimeSpan PortRetry = TimeSpan.FromSeconds(5);

    private readonly CancellationTokenSource quitting = new();
    private MainWindow? window;
    private TrayIcon? tray;
    private WebApplication? server;
    private volatile bool portInUse;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) => ErrorLog.Write(e.Exception);
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        var service = await Task.Run(() => PrintService.Open(new WindowsPrintBackend(), new ConfigStore(ConfigStore.DefaultPath)));
        LaunchAtLogin.Apply(service.LaunchAtLogin);

        window = new MainWindow(service, () => portInUse);
        tray = new TrayIcon(window.Handle, () => service.LaunchAtLogin);
        tray.OpenRequested += BringToFront;
        tray.LaunchAtLoginToggled += () =>
        {
            service.LaunchAtLogin = !service.LaunchAtLogin;
            LaunchAtLogin.Apply(service.LaunchAtLogin);
        };
        tray.QuitRequested += Quit;

        _ = ServeAsync(service);
        StartUpdates(service);
        if (!Environment.GetCommandLineArgs().Contains(LaunchAtLogin.TrayArgument)) BringToFront();
    }

    public void BringToFront() => window?.ShowAndActivate();

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

    private void StartUpdates(PrintService service)
    {
        string? testFeed = Environment.GetEnvironmentVariable(UpdateScheduler.TestFeedVariable) is { Length: > 0 } feed ? feed : null;
        var dispatcher = window!.DispatcherQueue;
        var updater = new VelopackUpdater(testFeed, () => dispatcher.TryEnqueue(Quit));
        var scheduler = new UpdateScheduler(updater, service, ErrorLog.Write, TimeProvider.System, fromTestFeed: testFeed is not null);
        _ = Task.Run(() => scheduler.RunAsync());
    }

    private async void Quit()
    {
        quitting.Cancel();
        tray?.Dispose();
        if (server is not null) await server.StopAsync();
        window?.CloseForQuit();
        Exit();
    }
}
