using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;

namespace NodePrint.Core.Tests;

public sealed class LocalApiTests
{
    private static readonly byte[] Pdf = "%PDF-1.4 test"u8.ToArray();

    private static AppConfig Chosen(string? label = null, string? document = null) =>
        new() { Channels = new ChannelChoices { Label = label, Document = document } };

    private static ByteArrayContent PdfBody(byte[]? bytes = null)
    {
        var content = new ByteArrayContent(bytes ?? Pdf);
        content.Headers.ContentType = new MediaTypeHeaderValue("application/pdf");
        return content;
    }

    private static async Task<JsonElement> JsonAsync(HttpResponseMessage response)
    {
        Assert.Equal("application/json; charset=utf-8", response.Content.Headers.ContentType?.ToString());
        return JsonDocument.Parse(await response.Content.ReadAsStringAsync()).RootElement;
    }

    private static async Task AssertErrorAsync(HttpResponseMessage response, HttpStatusCode status, string code)
    {
        Assert.Equal(status, response.StatusCode);
        var error = (await JsonAsync(response)).GetProperty("error");
        Assert.Equal(code, error.GetProperty("code").GetString());
        Assert.False(string.IsNullOrEmpty(error.GetProperty("message").GetString()));
    }

    [Fact]
    public async Task Status_reports_the_app_and_each_channel()
    {
        var backend = new FakeBackend();
        backend.Installed.Add(FakeBackend.Make("Zebra", PrinterKind.Thermal, PrinterState.Busy));
        await using var host = await TestHost.StartAsync(backend, Chosen(label: "Zebra"));

        var body = await JsonAsync(await host.Client.GetAsync("/status"));

        Assert.Equal("node-print", body.GetProperty("app").GetString());
        Assert.Equal(AppInfo.Version, body.GetProperty("version").GetString());
        Assert.Equal("windows", body.GetProperty("platform").GetString());
        var label = body.GetProperty("channels").GetProperty("label");
        Assert.Equal("busy", label.GetProperty("state").GetString());
        Assert.Equal("Zebra", label.GetProperty("printer").GetProperty("id").GetString());
        Assert.Equal("thermal", label.GetProperty("printer").GetProperty("kind").GetString());
        var document = body.GetProperty("channels").GetProperty("document");
        Assert.Equal("none", document.GetProperty("state").GetString());
        Assert.Equal(JsonValueKind.Null, document.GetProperty("printer").ValueKind);
    }

    [Fact]
    public async Task Status_says_missing_when_the_chosen_printer_is_gone()
    {
        await using var host = await TestHost.StartAsync(new FakeBackend(), Chosen(document: "Gone"));

        var document = (await JsonAsync(await host.Client.GetAsync("/status"))).GetProperty("channels").GetProperty("document");

        Assert.Equal("missing", document.GetProperty("state").GetString());
        var placeholder = document.GetProperty("printer");
        Assert.Equal(("Gone", "Gone", "", "other", "other", 0, 0, "offline", false), (
            placeholder.GetProperty("id").GetString(), placeholder.GetProperty("name").GetString(),
            placeholder.GetProperty("model").GetString(), placeholder.GetProperty("connection").GetString(),
            placeholder.GetProperty("kind").GetString(), placeholder.GetProperty("papers").GetArrayLength(),
            placeholder.GetProperty("dpi").GetInt32(), placeholder.GetProperty("state").GetString(),
            placeholder.GetProperty("default").GetBoolean()));
    }

    [Fact]
    public async Task Printers_lists_label_printers_first_then_by_name()
    {
        var backend = new FakeBackend();
        backend.Installed.AddRange([
            FakeBackend.Make("brother"), FakeBackend.Make("Zebra", PrinterKind.Thermal),
            FakeBackend.Make("Canon"), FakeBackend.Make("Rollo", PrinterKind.Thermal),
        ]);
        await using var host = await TestHost.StartAsync(backend);

        var printers = (await JsonAsync(await host.Client.GetAsync("/printers"))).GetProperty("printers");

        Assert.Equal(["Rollo", "Zebra", "brother", "Canon"], printers.EnumerateArray().Select(p => p.GetProperty("name").GetString()));
    }

    [Fact]
    public async Task Print_hands_the_job_to_the_chosen_printer()
    {
        var backend = new FakeBackend { Pages = _ => 3 };
        backend.Installed.Add(FakeBackend.Make("Brother"));
        await using var host = await TestHost.StartAsync(backend, Chosen(document: "Brother"));

        var response = await host.Client.PostAsync("/print?channel=document&copies=2&title=Pick%20sheet", PdfBody());

        var job = (await JsonAsync(response)).GetProperty("job");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("document", job.GetProperty("channel").GetString());
        Assert.Equal("Brother", job.GetProperty("printer").GetString());
        Assert.Equal(3, job.GetProperty("pages").GetInt32());
        Assert.Equal(2, job.GetProperty("copies").GetInt32());
        Assert.Equal(("Brother", Channel.Document, 2, "Pick sheet", Pdf.Length), Assert.Single(backend.Jobs));
    }

    [Fact]
    public async Task Print_defaults_to_one_copy_and_the_channel_title()
    {
        var backend = new FakeBackend();
        backend.Installed.Add(FakeBackend.Make("Zebra", PrinterKind.Thermal));
        await using var host = await TestHost.StartAsync(backend, Chosen(label: "Zebra"));

        await host.Client.PostAsync("/print?channel=label", PdfBody());

        var job = Assert.Single(backend.Jobs);
        Assert.Equal((1, "NODE label"), (job.Copies, job.Title));
    }

    [Theory]
    [InlineData("/print")]
    [InlineData("/print?channel=labels")]
    [InlineData("/print?channel=Label")]
    [InlineData("/print?channel=label&channel=document")]
    public async Task Print_rejects_a_missing_or_unknown_channel(string url)
    {
        await using var host = await TestHost.StartAsync(new FakeBackend());

        await AssertErrorAsync(await host.Client.PostAsync(url, PdfBody()), HttpStatusCode.BadRequest, "BAD_CHANNEL");
    }

    [Theory]
    [InlineData("0")]
    [InlineData("100")]
    [InlineData("two")]
    [InlineData("1.5")]
    [InlineData("")]
    public async Task Print_rejects_copies_outside_1_to_99(string copies)
    {
        await using var host = await TestHost.StartAsync(new FakeBackend());

        var response = await host.Client.PostAsync($"/print?channel=label&copies={copies}", PdfBody());

        await AssertErrorAsync(response, HttpStatusCode.BadRequest, "BAD_COPIES");
    }

    [Fact]
    public async Task Print_decodes_a_plus_in_the_title_as_a_space()
    {
        var backend = new FakeBackend();
        backend.Installed.Add(FakeBackend.Make("Zebra"));
        await using var host = await TestHost.StartAsync(backend, Chosen(label: "Zebra"));

        await host.Client.PostAsync("/print?channel=label&title=Order+1001%20label", PdfBody());

        Assert.Equal("Order 1001 label", Assert.Single(backend.Jobs).Title);
    }

    [Fact]
    public async Task Print_rejects_a_body_the_backend_cannot_open()
    {
        var backend = new FakeBackend { Pages = _ => throw ApiError.BadDocument("not a PDF") };
        backend.Installed.Add(FakeBackend.Make("Zebra"));
        await using var host = await TestHost.StartAsync(backend, Chosen(label: "Zebra"));

        await AssertErrorAsync(await host.Client.PostAsync("/print?channel=label", PdfBody("hello"u8.ToArray())),
            HttpStatusCode.BadRequest, "BAD_DOCUMENT");
    }

    [Fact]
    public async Task Print_rejects_a_declared_length_over_50_MB_without_reading_it()
    {
        await using var host = await TestHost.StartAsync(new FakeBackend());
        var content = PdfBody();
        content.Headers.ContentLength = LocalApi.MaxBodyBytes + 1;

        await AssertErrorAsync(await host.Client.PostAsync("/print?channel=label", content), HttpStatusCode.RequestEntityTooLarge,
            "TOO_LARGE");
    }

    [Fact]
    public async Task Print_accepts_a_body_of_exactly_the_limit()
    {
        var backend = new FakeBackend();
        backend.Installed.Add(FakeBackend.Make("Zebra"));
        await using var host = await TestHost.StartAsync(backend, Chosen(label: "Zebra"));
        var content = new StreamContent(new ZeroStream(LocalApi.MaxBodyBytes));

        var response = await host.Client.PostAsync("/print?channel=label", content);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal(LocalApi.MaxBodyBytes, Assert.Single(backend.Jobs).Bytes);
    }

    [Fact]
    public async Task Print_rejects_a_streamed_body_once_it_passes_50_MB()
    {
        var backend = new FakeBackend();
        backend.Installed.Add(FakeBackend.Make("Zebra"));
        await using var host = await TestHost.StartAsync(backend, Chosen(label: "Zebra"));
        var content = new StreamContent(new ZeroStream(LocalApi.MaxBodyBytes + 1));

        await AssertErrorAsync(await host.Client.PostAsync("/print?channel=label", content), HttpStatusCode.RequestEntityTooLarge,
            "TOO_LARGE");
        Assert.Empty(backend.Jobs);
    }

    [Fact]
    public async Task Print_needs_a_chosen_printer()
    {
        await using var host = await TestHost.StartAsync(new FakeBackend());

        await AssertErrorAsync(await host.Client.PostAsync("/print?channel=document", PdfBody()), HttpStatusCode.Conflict,
            "NO_PRINTER");
    }

    [Theory]
    [InlineData(null)]
    [InlineData(PrinterState.Offline)]
    [InlineData(PrinterState.Error)]
    [InlineData(PrinterState.Paused)]
    public async Task Print_refuses_a_missing_offline_failing_or_paused_printer(PrinterState? state)
    {
        var backend = new FakeBackend();
        if (state is { } s) backend.Installed.Add(FakeBackend.Make("Zebra", state: s));
        await using var host = await TestHost.StartAsync(backend, Chosen(label: "Zebra"));

        await AssertErrorAsync(await host.Client.PostAsync("/print?channel=label", PdfBody()), HttpStatusCode.Conflict,
            "PRINTER_UNAVAILABLE");
        Assert.Empty(backend.Jobs);
    }

    [Fact]
    public async Task Print_queues_on_a_busy_printer()
    {
        var backend = new FakeBackend();
        backend.Installed.Add(FakeBackend.Make("Zebra", state: PrinterState.Busy));
        await using var host = await TestHost.StartAsync(backend, Chosen(label: "Zebra"));

        var response = await host.Client.PostAsync("/print?channel=label", PdfBody());

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Fact]
    public async Task Print_reports_what_the_os_refused()
    {
        var backend = new FakeBackend { Pages = _ => throw ApiError.PrintFailed("Zebra", "access denied") };
        backend.Installed.Add(FakeBackend.Make("Zebra"));
        await using var host = await TestHost.StartAsync(backend, Chosen(label: "Zebra"));

        var response = await host.Client.PostAsync("/print?channel=label", PdfBody());

        await AssertErrorAsync(response, HttpStatusCode.InternalServerError, "PRINT_FAILED");
    }

    [Fact]
    public async Task Unknown_paths_are_not_found()
    {
        await using var host = await TestHost.StartAsync(new FakeBackend());

        await AssertErrorAsync(await host.Client.GetAsync("/statuses"), HttpStatusCode.NotFound, "NOT_FOUND");
    }

    [Theory]
    [InlineData("POST", "/status")]
    [InlineData("DELETE", "/printers")]
    [InlineData("GET", "/print")]
    public async Task Known_paths_refuse_other_methods(string method, string path)
    {
        await using var host = await TestHost.StartAsync(new FakeBackend());

        var response = await host.Client.SendAsync(new HttpRequestMessage(new HttpMethod(method), path));

        await AssertErrorAsync(response, HttpStatusCode.MethodNotAllowed, "METHOD_NOT_ALLOWED");
    }

    [Theory]
    [InlineData("https://nrp.node.live")]
    [InlineData("http://localhost:5173")]
    [InlineData("http://127.0.0.1:5173")]
    [InlineData("https://staging.example.com")]
    public async Task Allowed_origins_get_the_cors_headers(string origin)
    {
        var config = new AppConfig { AllowedOrigins = ["https://staging.example.com"] };
        await using var host = await TestHost.StartAsync(new FakeBackend(), config);
        var request = new HttpRequestMessage(HttpMethod.Get, "/status");
        request.Headers.Add("Origin", origin);

        var response = await host.Client.SendAsync(request);

        Assert.Equal(origin, Header(response, "Access-Control-Allow-Origin"));
        Assert.Equal("GET, POST, OPTIONS", Header(response, "Access-Control-Allow-Methods"));
        Assert.Equal("Content-Type", Header(response, "Access-Control-Allow-Headers"));
        Assert.Equal("true", Header(response, "Access-Control-Allow-Private-Network"));
        Assert.Equal("600", Header(response, "Access-Control-Max-Age"));
    }

    [Fact]
    public async Task Preflight_from_an_allowed_origin_is_204()
    {
        await using var host = await TestHost.StartAsync(new FakeBackend());
        var request = new HttpRequestMessage(HttpMethod.Options, "/print?channel=label");
        request.Headers.Add("Origin", "https://nrp.node.live");
        request.Headers.Add("Access-Control-Request-Method", "POST");
        request.Headers.Add("Access-Control-Request-Private-Network", "true");

        var response = await host.Client.SendAsync(request);

        Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
        Assert.Equal("https://nrp.node.live", Header(response, "Access-Control-Allow-Origin"));
        Assert.Equal("true", Header(response, "Access-Control-Allow-Private-Network"));
    }

    [Fact]
    public async Task Checks_run_in_the_protocol_order()
    {
        await using var host = await TestHost.StartAsync(new FakeBackend());
        var tooLarge = PdfBody("garbage"u8.ToArray());
        tooLarge.Headers.ContentLength = LocalApi.MaxBodyBytes + 1;
        var foreign = new HttpRequestMessage(HttpMethod.Post, "/print?copies=0") { Content = PdfBody() };
        foreign.Headers.Add("Origin", "https://evil.example.com");

        await AssertErrorAsync(await host.Client.SendAsync(foreign), HttpStatusCode.Forbidden, "FORBIDDEN_ORIGIN");
        await AssertErrorAsync(await host.Client.PostAsync("/print?copies=0", PdfBody()), HttpStatusCode.BadRequest, "BAD_CHANNEL");
        await AssertErrorAsync(await host.Client.PostAsync("/print?channel=label&copies=0", tooLarge), HttpStatusCode.BadRequest,
            "BAD_COPIES");
        await AssertErrorAsync(await host.Client.PostAsync("/print?channel=label", tooLarge), HttpStatusCode.RequestEntityTooLarge,
            "TOO_LARGE");
        await AssertErrorAsync(await host.Client.PostAsync("/print?channel=label", PdfBody("garbage"u8.ToArray())),
            HttpStatusCode.Conflict, "NO_PRINTER");
    }

    [Theory]
    [InlineData("GET", "/status", "https://evil.example.com")]
    [InlineData("OPTIONS", "/print", "https://evil.example.com")]
    [InlineData("POST", "/print?channel=label", "https://evil.example.com")]
    [InlineData("POST", "/print?channel=label", "http://nrp.node.live")]
    [InlineData("POST", "/print?channel=label", "null")]
    public async Task Other_origins_are_forbidden_and_nothing_is_done(string method, string path, string origin)
    {
        var backend = new FakeBackend();
        backend.Installed.Add(FakeBackend.Make("Zebra"));
        await using var host = await TestHost.StartAsync(backend, Chosen(label: "Zebra"));
        var request = new HttpRequestMessage(new HttpMethod(method), path) { Content = PdfBody() };
        request.Headers.Add("Origin", origin);

        var response = await host.Client.SendAsync(request);

        await AssertErrorAsync(response, HttpStatusCode.Forbidden, "FORBIDDEN_ORIGIN");
        Assert.DoesNotContain(response.Headers, h => h.Key.StartsWith("Access-Control-", StringComparison.OrdinalIgnoreCase));
        Assert.Empty(backend.Jobs);
    }

    [Fact]
    public async Task A_preflight_on_any_path_is_204()
    {
        await using var host = await TestHost.StartAsync(new FakeBackend());
        var request = new HttpRequestMessage(HttpMethod.Options, "/anything");
        request.Headers.Add("Origin", "http://localhost:5173");

        var response = await host.Client.SendAsync(request);

        Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
        Assert.Equal("http://localhost:5173", Header(response, "Access-Control-Allow-Origin"));
    }

    private static string? Header(HttpResponseMessage response, string name) =>
        response.Headers.TryGetValues(name, out var values) ? string.Join(",", values) : null;

    private sealed class ZeroStream(long length) : Stream
    {
        private long position;

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => position; set => throw new NotSupportedException(); }

        public override int Read(byte[] buffer, int offset, int count)
        {
            int n = (int)Math.Min(count, length - position);
            Array.Clear(buffer, offset, n);
            position += n;
            return n;
        }

        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
