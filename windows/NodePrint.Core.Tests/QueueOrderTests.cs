namespace NodePrint.Core.Tests;

public sealed class QueueOrderTests : IDisposable
{
    private readonly DirectoryInfo directory = Directory.CreateTempSubdirectory("nodeprint-");

    public void Dispose() => directory.Delete(true);

    [Fact]
    public async Task A_job_keeps_its_place_from_the_moment_its_body_is_in_even_when_it_is_slow_to_open()
    {
        var backend = new FakeBackend();
        backend.Installed.Add(FakeBackend.Make("Zebra"));
        var slowToOpen = new TaskCompletionSource();
        backend.Starting = body => body.Length > 1000 ? slowToOpen.Task : Task.CompletedTask;
        var service = new PrintService(backend, new ConfigStore(Path.Combine(directory.FullName, "config.json")),
            new AppConfig { Channels = new ChannelChoices { Label = "Zebra" } });

        var large = service.PrintAsync(Channel.Label, 1, "large", new byte[100_000]);
        var small = service.PrintAsync(Channel.Label, 1, "small", new byte[10]);
        Assert.False(small.IsCompleted);
        slowToOpen.SetResult();
        await Task.WhenAll(large, small);

        Assert.Equal(["large", "small"], backend.Jobs.Select(j => j.Title));
    }

    [Fact]
    public async Task A_job_prints_on_the_printer_chosen_when_its_body_came_in()
    {
        var backend = new FakeBackend();
        backend.Installed.AddRange([FakeBackend.Make("Zebra"), FakeBackend.Make("Rollo")]);
        var first = new TaskCompletionSource();
        backend.Starting = body => body.Length > 1000 ? first.Task : Task.CompletedTask;
        var service = new PrintService(backend, new ConfigStore(Path.Combine(directory.FullName, "config.json")),
            new AppConfig { Channels = new ChannelChoices { Label = "Zebra" } });

        var waiting = service.PrintAsync(Channel.Label, 1, "first", new byte[100_000]);
        var queued = service.PrintAsync(Channel.Label, 1, "second", new byte[10]);
        service.Choose(Channel.Label, "Rollo");
        first.SetResult();
        await Task.WhenAll(waiting, queued);

        Assert.Equal(["Zebra", "Zebra"], backend.Jobs.Select(j => j.Printer));
    }
}
