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
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        var service = await Task.Run(() => PrintService.Open(new WindowsPrintBackend(), new ConfigStore(ConfigStore.DefaultPath)));
        LaunchAtLogin.Apply(service.LaunchAtLogin);

        window = new MainWindow(service);
        tray = new TrayIcon(window.Handle, () => service.LaunchAtLogin);
        tray.OpenRequested += BringToFront;
        tray.LaunchAtLoginToggled += () =>
        {
            service.LaunchAtLogin = !service.LaunchAtLogin;
            LaunchAtLogin.Apply(service.LaunchAtLogin);
        };
        tray.QuitRequested += Quit;

        server = LocalApi.Create(service);
        await server.StartAsync();

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
