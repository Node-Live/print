using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.TestHost;

namespace NodePrint.Core.Tests;

internal sealed class FakeBackend : IPrintBackend
{
    public List<Printer> Installed { get; } = [];
    public List<(string Printer, Channel Channel, int Copies, string Title, int Bytes)> Jobs { get; } = [];
    public Func<ReadOnlyMemory<byte>, int> Pages { get; set; } = _ => 1;

    /// <summary>Runs as a job starts printing, before it is recorded; a test can hold a job here.</summary>
    public Func<ReadOnlyMemory<byte>, Task> Starting { get; set; } = _ => Task.CompletedTask;

    /// <summary>Thrown from GetPrinters, as when the spooler is not running.</summary>
    public Exception? Failure { get; set; }

    public IReadOnlyList<Printer> GetPrinters() => Failure is null ? Installed : throw Failure;

    public Printer? FindPrinter(string id) => Installed.FirstOrDefault(p => p.Id == id);

    public async Task<int> PrintAsync(Printer printer, Channel channel, ReadOnlyMemory<byte> document, int copies, string title)
    {
        await Starting(document);
        int pages = Pages(document);
        Jobs.Add((printer.Id, channel, copies, title, document.Length));
        return pages;
    }

    public static Printer Make(string name, PrinterKind kind = PrinterKind.Other, PrinterState state = PrinterState.Ready,
        bool isDefault = false) =>
        new(name, name, "", Connection.Usb, kind, [], 0, state, "", isDefault);
}

internal sealed class TestHost : IAsyncDisposable
{
    private readonly WebApplication app;
    private readonly DirectoryInfo directory;

    private TestHost(WebApplication app, PrintService service, DirectoryInfo directory)
    {
        this.app = app;
        this.directory = directory;
        Service = service;
        Client = app.GetTestClient();
    }

    public HttpClient Client { get; }
    public PrintService Service { get; }

    public static async Task<TestHost> StartAsync(FakeBackend backend, AppConfig? config = null, TimeProvider? clock = null)
    {
        var directory = Directory.CreateTempSubdirectory("nodeprint-");
        var store = new ConfigStore(Path.Combine(directory.FullName, "config.json"));
        var service = new PrintService(backend, store, config ?? new AppConfig(), clock);
        var builder = WebApplication.CreateEmptyBuilder(new WebApplicationOptions());
        builder.WebHost.UseTestServer();
        var app = builder.Build();
        LocalApi.Map(app, service);
        await app.StartAsync();
        return new TestHost(app, service, directory);
    }

    public async ValueTask DisposeAsync()
    {
        await app.DisposeAsync();
        directory.Delete(true);
    }
}
