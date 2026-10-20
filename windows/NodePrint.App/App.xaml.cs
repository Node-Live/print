using Microsoft.AspNetCore.Builder;
using Microsoft.UI.Xaml;
using NodePrint.Core;
using NodePrint.Printing;

namespace NodePrint.App;

public partial class App : Application
{
    private MainWindow? window;
    private TrayIcon? tray;
    private WebApplication? server;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) => ErrorLog.Write(e.Exception);
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        ErrorLog.Write("trace: launched");
        var service = await Task.Run(() => PrintService.Open(new WindowsPrintBackend(), new ConfigStore(ConfigStore.DefaultPath)));
        LaunchAtLogin.Apply(service.LaunchAtLogin);

        ErrorLog.Write("trace: service");
        window = new MainWindow(service);
        ErrorLog.Write("trace: window");
        tray = new TrayIcon(window.Handle, () => service.LaunchAtLogin);
        tray.OpenRequested += BringToFront;
        tray.LaunchAtLoginToggled += () =>
        {
            service.LaunchAtLogin = !service.LaunchAtLogin;
            LaunchAtLogin.Apply(service.LaunchAtLogin);
        };
        tray.QuitRequested += Quit;
        ErrorLog.Write("trace: tray");

        try
        {
            server = LocalApi.Create(service);
            await server.StartAsync();
            ErrorLog.Write("trace: listening");
        }
        catch (IOException e)
        {
            // Most likely another program holds the port; the window still shows the printers.
            ErrorLog.Write(e);
        }

        if (!Environment.GetCommandLineArgs().Contains(LaunchAtLogin.TrayArgument))
        {
            window.ShowAndActivate();
        }
    }

    public void BringToFront() => window?.ShowAndActivate();

    private async void Quit()
    {
        tray?.Dispose();
        if (server is not null) await server.StopAsync();
        window?.CloseForQuit();
        Exit();
    }
}
