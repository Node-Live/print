using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using Velopack;
using Windows.Win32;

namespace NodePrint.App;

public static class Program
{
    [STAThread]
    private static int Main()
    {
        AppDomain.CurrentDomain.UnhandledException += (_, e) => ErrorLog.Write(e.ExceptionObject);
        TaskScheduler.UnobservedTaskException += (_, e) => ErrorLog.Write(e.Exception);
        VelopackApp.Build().Run();
        WinRT.ComWrappersSupport.InitializeComWrappers();

        ErrorLog.Write("trace: main");
        var instance = AppInstance.FindOrRegisterForKey("NODE Print");
        ErrorLog.Write($"trace: instance current={instance.IsCurrent}");
        if (!instance.IsCurrent)
        {
            // The running copy brings its window up; it may only take the foreground if this one hands it over.
            PInvoke.AllowSetForegroundWindow(instance.ProcessId);
            var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
            Task.Run(() => instance.RedirectActivationToAsync(activation).AsTask()).Wait();
            return 0;
        }

        Application.Start(_ =>
        {
            var dispatcher = DispatcherQueue.GetForCurrentThread();
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(dispatcher));
            var app = new App();
            instance.Activated += (_, _) => dispatcher.TryEnqueue(app.BringToFront);
        });
        return 0;
    }
}
