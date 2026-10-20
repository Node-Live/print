using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using Velopack;
using Windows.Win32;

namespace NodePrint.App;

public static class Program
{
    // Held for the life of the process: the port belongs to the machine, so one copy runs per machine.
    private static Mutex? machineWide;

    [STAThread]
    private static int Main()
    {
        AppDomain.CurrentDomain.UnhandledException += (_, e) => ErrorLog.Write(e.ExceptionObject);
        TaskScheduler.UnobservedTaskException += (_, e) => ErrorLog.Write(e.Exception);
        VelopackApp.Build().Run();
        if (!RuntimeSetup.Ensure()) return 1;
        WinRT.ComWrappersSupport.InitializeComWrappers();

        bool first = TakeMachine();
        var instance = AppInstance.FindOrRegisterForKey("NODE Print");
        if (!first || !instance.IsCurrent)
        {
            if (!instance.IsCurrent)
            {
                // The running copy brings its window up; it may only take the foreground if this one hands it over.
                PInvoke.AllowSetForegroundWindow(instance.ProcessId);
                var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
                Task.Run(() => instance.RedirectActivationToAsync(activation).AsTask()).Wait();
            }
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

    /// <summary>False when a copy already runs on this machine, in this session or another user's.</summary>
    private static bool TakeMachine()
    {
        try
        {
            machineWide = new Mutex(false, @"Global\NODE Print");
            return machineWide.WaitOne(0);
        }
        catch (AbandonedMutexException)
        {
            return true;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }
}
