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
        VelopackApp.Build().Run();
        WinRT.ComWrappersSupport.InitializeComWrappers();

        var instance = AppInstance.FindOrRegisterForKey("NODE Print");
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
