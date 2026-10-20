using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.TestHost;

namespace NodePrint.Core.Tests;

internal sealed class FakeBackend : IPrintBackend
{
    public List<Printer> Installed { get; } = [];
    public List<(string Printer, Channel Channel, int Copies, string Title, int Bytes)> Jobs { get; } = [];
    public Func<ReadOnlyMemory<byte>, int> Pages { get; set; } = _ => 1;

    public IReadOnlyList<Printer> GetPrinters() => Installed;

    public Printer? FindPrinter(string id) => Installed.FirstOrDefault(p => p.Id == id);

    public Task<int> PrintAsync(Printer printer, Channel channel, ReadOnlyMemory<byte> pdf, int copies, string title)
    {
        int pages = Pages(pdf);
        Jobs.Add((printer.Id, channel, copies, title, pdf.Length));
        return Task.FromResult(pages);
    }

    public static Printer Make(string name, PrinterKind kind = PrinterKind.Other, PrinterState state = PrinterState.Ready,
        bool isDefault = false) =>
        new(name, name, "", Connection.Usb, kind, [], PrinterLanguage.Driver, 0, state, "", isDefault);
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

    public static async Task<TestHost> StartAsync(FakeBackend backend, AppConfig? config = null)
    {
        var directory = Directory.CreateTempSubdirectory("nodeprint-");
        var store = new ConfigStore(Path.Combine(directory.FullName, "config.json"));
        var service = new PrintService(backend, store, config ?? new AppConfig());
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
