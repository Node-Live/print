using Microsoft.Extensions.Time.Testing;

namespace NodePrint.Core.Tests;

internal sealed class FakeUpdater : IUpdater
{
    public string? Newer { get; set; }
    public string? Downloaded { get; set; }
    public Exception? Failure { get; set; }

    /// <summary>Runs while the download is in progress; a test can bring a job in here.</summary>
    public Action Downloading { get; set; } = () => { };

    public SemaphoreSlim Checked { get; } = new(0);
    public int Checks { get; private set; }
    public int Downloads { get; private set; }
    public int Applies { get; private set; }

    public Task<string?> CheckAsync()
    {
        Checks++;
        Checked.Release();
        return Failure is null ? Task.FromResult(Newer) : Task.FromException<string?>(Failure);
    }

    public Task DownloadAsync()
    {
        Downloads++;
        Downloading();
        Downloaded = Newer;
        return Task.CompletedTask;
    }

    public void Apply() => Applies++;
}

public sealed class UpdateSchedulerTests : IDisposable
{
    private readonly DirectoryInfo directory = Directory.CreateTempSubdirectory("nodeprint-");
    private readonly FakeTimeProvider clock = new();
    private readonly FakeUpdater updater = new();
    private readonly List<string> log = [];
    private readonly PrintService service;

    public UpdateSchedulerTests()
    {
        service = new PrintService(new FakeBackend(), new ConfigStore(Path.Combine(directory.FullName, "config.json")),
            new AppConfig(), clock);
    }

    public void Dispose() => directory.Delete(true);

    private UpdateScheduler Scheduler(bool fromTestFeed = false) => new(updater, service, log.Add, clock, fromTestFeed);

    [Fact]
    public async Task The_first_check_runs_an_hour_after_start_then_every_hour()
    {
        _ = Scheduler().RunAsync();

        clock.Advance(TimeSpan.FromMinutes(59));
        Assert.Equal(0, updater.Checks);
        clock.Advance(TimeSpan.FromMinutes(1));
        Assert.True(await updater.Checked.WaitAsync(TimeSpan.FromSeconds(5)));
        clock.Advance(TimeSpan.FromHours(1));
        Assert.True(await updater.Checked.WaitAsync(TimeSpan.FromSeconds(5)));

        Assert.Equal(2, updater.Checks);
    }

    [Fact]
    public async Task A_test_feed_brings_the_first_check_to_2_seconds_after_start()
    {
        _ = Scheduler(fromTestFeed: true).RunAsync();

        clock.Advance(TimeSpan.FromSeconds(1));
        Assert.Equal(0, updater.Checks);
        clock.Advance(TimeSpan.FromSeconds(1));

        Assert.True(await updater.Checked.WaitAsync(TimeSpan.FromSeconds(5)));
    }

    [Fact]
    public async Task A_tick_while_a_job_is_in_flight_does_nothing()
    {
        updater.Newer = "1.0.1";
        using var job = service.JobArrived();

        await Scheduler().TickAsync();

        Assert.Equal((0, 0, 0), (updater.Checks, updater.Downloads, updater.Applies));
        Assert.Empty(log);
    }

    [Fact]
    public async Task A_tick_that_finds_nothing_newer_downloads_nothing_and_logs_nothing()
    {
        await Scheduler().TickAsync();

        Assert.Equal((1, 0, 0), (updater.Checks, updater.Downloads, updater.Applies));
        Assert.Empty(log);
    }

    [Fact]
    public async Task An_update_is_downloaded_and_applied_when_the_app_is_idle()
    {
        updater.Newer = "1.0.1";

        await Scheduler().TickAsync();

        Assert.Equal((1, 1, 1), (updater.Checks, updater.Downloads, updater.Applies));
        Assert.Contains("1.0.1", Assert.Single(log));
    }

    [Fact]
    public async Task A_job_arriving_during_the_download_keeps_the_update_for_a_later_tick()
    {
        updater.Newer = "1.0.1";
        IDisposable? job = null;
        updater.Downloading = () => job = service.JobArrived();

        await Scheduler().TickAsync();
        job?.Dispose();

        Assert.Equal((1, 1, 0), (updater.Checks, updater.Downloads, updater.Applies));
        Assert.Equal("1.0.1", updater.Downloaded);
        Assert.Contains("1.0.1", Assert.Single(log));
    }

    [Fact]
    public async Task A_kept_download_is_applied_at_a_later_idle_tick_without_downloading_again()
    {
        updater.Downloaded = "1.0.1";

        await Scheduler().TickAsync();

        Assert.Equal((0, 0, 1), (updater.Checks, updater.Downloads, updater.Applies));
        Assert.Contains("1.0.1", Assert.Single(log));
    }

    [Fact]
    public async Task A_failure_is_logged_and_the_next_tick_tries_again()
    {
        updater.Failure = new HttpRequestException("rate limit exceeded");
        var scheduler = Scheduler();

        await scheduler.TickAsync();
        updater.Failure = null;
        updater.Newer = "1.0.1";
        await scheduler.TickAsync();

        Assert.Contains("rate limit exceeded", log[0]);
        Assert.Equal((2, 1, 1), (updater.Checks, updater.Downloads, updater.Applies));
    }
}
