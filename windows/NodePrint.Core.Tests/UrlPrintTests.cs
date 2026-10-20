using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;

namespace NodePrint.Core.Tests;

/// <summary>The URL form of a print request, against a real HTTP server on the loopback.</summary>
public sealed class UrlPrintTests : IAsyncLifetime
{
    private static readonly byte[] Pdf = "%PDF-1.4 label"u8.ToArray();
    private readonly TaskCompletionSource slowGate = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private WebApplication? files;
    private int requests;

    private string Base { get; set; } = "";

    public async ValueTask InitializeAsync()
    {
        var builder = WebApplication.CreateEmptyBuilder(new WebApplicationOptions());
        builder.WebHost.UseKestrelCore().ConfigureKestrel(k => k.Listen(IPAddress.Loopback, 0));
        files = builder.Build();
        files.Run(async context =>
        {
            Interlocked.Increment(ref requests);
            switch (context.Request.Path.Value)
            {
                case "/label.pdf":
                    await context.Response.Body.WriteAsync(Pdf);
                    break;
                case "/redirect":
                    context.Response.Redirect("/label.pdf");
                    break;
                case "/huge":
                    context.Response.ContentLength = LocalApi.MaxBodyBytes + 1;
                    await context.Response.Body.WriteAsync(new byte[1024]);
                    break;
                case "/slow":
                    await slowGate.Task;
                    await context.Response.Body.WriteAsync(Pdf);
                    break;
                default:
                    context.Response.StatusCode = 404;
                    break;
            }
        });
        await files.StartAsync();
        Base = files.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!.Addresses.First();
    }

    public async ValueTask DisposeAsync()
    {
        slowGate.TrySetResult();
        if (files is not null) await files.DisposeAsync();
    }

    private static FakeBackend Backend()
    {
        var backend = new FakeBackend();
        backend.Installed.Add(FakeBackend.Make("Zebra"));
        return backend;
    }

    private static AppConfig Chosen() => new() { Channels = new ChannelChoices { Label = "Zebra" } };

    private static StringContent Json(string json) => new(json, Encoding.UTF8, "application/json");

    private static async Task<string?> CodeAsync(HttpResponseMessage response) =>
        JsonDocument.Parse(await response.Content.ReadAsStringAsync()).RootElement.GetProperty("error").GetProperty("code").GetString();

    [Fact]
    public async Task Downloads_the_document_following_redirects_and_prints_it()
    {
        var backend = Backend();
        await using var host = await TestHost.StartAsync(backend, Chosen());

        var response = await host.Client.PostAsync("/print?channel=label",
            JsonContent.Create(new { url = Base + "/redirect" }));

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal(Pdf.Length, Assert.Single(backend.Jobs).Bytes);
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("{\"url\": null}")]
    [InlineData("{\"url\": \"ftp://example.com/label.pdf\"}")]
    [InlineData("{\"url\": \"/label.pdf\"}")]
    [InlineData("not json")]
    public async Task A_json_body_without_an_http_url_is_a_bad_url(string json)
    {
        var backend = Backend();
        await using var host = await TestHost.StartAsync(backend, Chosen());

        var response = await host.Client.PostAsync("/print?channel=label", Json(json));

        Assert.Equal((HttpStatusCode.BadRequest, "BAD_URL"), (response.StatusCode, await CodeAsync(response)));
        Assert.Empty(backend.Jobs);
    }

    [Theory]
    [InlineData("/missing")]
    [InlineData("/huge")]
    public async Task A_download_that_fails_or_is_too_large_is_fetch_failed(string path)
    {
        var backend = Backend();
        await using var host = await TestHost.StartAsync(backend, Chosen());

        var response = await host.Client.PostAsync("/print?channel=label", JsonContent.Create(new { url = Base + path }));

        Assert.Equal((HttpStatusCode.BadGateway, "FETCH_FAILED"), (response.StatusCode, await CodeAsync(response)));
        Assert.Empty(backend.Jobs);
    }

    [Fact]
    public async Task Nothing_is_downloaded_for_a_channel_without_a_printer()
    {
        await using var host = await TestHost.StartAsync(new FakeBackend());

        var response = await host.Client.PostAsync("/print?channel=label", JsonContent.Create(new { url = Base + "/label.pdf" }));

        Assert.Equal("NO_PRINTER", await CodeAsync(response));
        Assert.Equal(0, requests);
    }

    [Fact]
    public async Task A_url_job_keeps_its_place_while_it_downloads()
    {
        var backend = Backend();
        var service = new PrintService(backend, new ConfigStore(Path.Combine(Path.GetTempPath(), $"nodeprint-{Guid.NewGuid()}.json")), Chosen());

        var downloading = service.PrintAsync(Channel.Label, 1, "url", () => UrlFetcher.FetchAsync(new Uri(Base + "/slow")));
        var bytes = service.PrintAsync(Channel.Label, 1, "bytes", Pdf);
        Assert.False(bytes.IsCompleted);
        slowGate.SetResult();
        await Task.WhenAll(downloading, bytes);

        Assert.Equal(["url", "bytes"], backend.Jobs.Select(j => j.Title));
    }
}
