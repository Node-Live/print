namespace NodePrint.Core;

/// <summary>The platform's updater as <see cref="UpdateScheduler"/> drives it, one release at a time.</summary>
public interface IUpdater
{
    /// <summary>The version an earlier tick downloaded and did not apply, or null.</summary>
    string? Downloaded { get; }

    /// <summary>The version of the newest release when it is newer than the app's own, else null.</summary>
    Task<string?> CheckAsync();

    /// <summary>Downloads the release the last check found.</summary>
    Task DownloadAsync();

    /// <summary>Hands the downloaded version to the swap, stops the local server and exits; the new version starts
    /// in the tray.</summary>
    void Apply();
}

/// <summary>Checks for a newer version every hour while the app is idle and installs it without asking.</summary>
public sealed class UpdateScheduler(IUpdater updater, PrintService service, Action<string> log, TimeProvider clock, bool fromTestFeed)
{
    /// <summary>An update feed to read instead of the GitHub releases; the first check then runs 2 seconds after start.</summary>
    public const string TestFeedVariable = "NODE_PRINT_UPDATES";

    public static readonly TimeSpan Interval = TimeSpan.FromHours(1);
    public static readonly TimeSpan TestFeedFirstTick = TimeSpan.FromSeconds(2);

    public async Task RunAsync()
    {
        using var hourly = new PeriodicTimer(Interval, clock);
        if (fromTestFeed)
        {
            await Task.Delay(TestFeedFirstTick, clock);
            await TickAsync();
        }
        while (await hourly.WaitForNextTickAsync())
        {
            await TickAsync();
        }
    }

    internal async Task TickAsync()
    {
        if (!service.IsIdle(clock.GetUtcNow())) return;
        try
        {
            if (updater.Downloaded is { } kept)
            {
                log($"Update {kept}, downloaded earlier, is being installed.");
            }
            else
            {
                if (await updater.CheckAsync() is not { } version) return;
                await updater.DownloadAsync();
                if (!service.IsIdle(clock.GetUtcNow()))
                {
                    log($"Update {version} downloaded; a print job came in, so it is installed at the next idle check.");
                    return;
                }
                log($"Update {version} downloaded and is being installed.");
            }
            updater.Apply();
        }
        catch (Exception e)
        {
            log($"Update failed: {e.GetType().Name}: {e.Message}");
        }
    }
}
