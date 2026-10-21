using NodePrint.Core;
using Velopack;
using Velopack.Sources;

namespace NodePrint.App;

/// <summary>Velopack, which installed the app, finds, downloads and swaps in new versions from the GitHub releases, or
/// from the test feed when one is set.</summary>
internal sealed class VelopackUpdater(string? testFeed, Action quit) : IUpdater
{
    private readonly UpdateManager manager = new(testFeed is null
        ? new GithubSource("https://github.com/Node-Live/print", null, prerelease: false)
        : (IUpdateSource)new SimpleWebSource(testFeed));
    private UpdateInfo? found;
    private bool notInstalledLogged;

    public string? Downloaded => manager.UpdatePendingRestart?.Version.ToString();

    public async Task<string?> CheckAsync()
    {
        if (!manager.IsInstalled)
        {
            if (!notInstalledLogged) ErrorLog.Write("Updates are off: this copy of NODE Print was not installed by its setup.");
            notInstalledLogged = true;
            return null;
        }
        found = await manager.CheckForUpdatesAsync();
        return found?.TargetFullRelease.Version.ToString();
    }

    public Task DownloadAsync() => manager.DownloadUpdatesAsync(found!);

    public void Apply()
    {
        var update = manager.UpdatePendingRestart ?? throw new InvalidOperationException("No downloaded update to apply.");
        // ApplyUpdatesAndRestart, but silent: without --silent Update.exe shows a progress window during the swap.
        // Update.exe waits for this process to exit before it replaces current\.
        manager.WaitExitThenApplyUpdates(update, silent: true, restart: true, [LaunchAtLogin.TrayArgument]);
        quit();
    }
}
