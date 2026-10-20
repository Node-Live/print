using System.Globalization;
using System.Net;
using System.Text.Json.Serialization.Metadata;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;

namespace NodePrint.Core;

public static class LocalApi
{
    public const int Port = 19233;
    public const long MaxBodyBytes = 50L * 1024 * 1024;

    public static readonly IReadOnlyList<string> BuiltInOrigins =
        ["https://nrp.node.live", "http://localhost:5173", "http://127.0.0.1:5173"];

    public static WebApplication Create(PrintService service)
    {
        var builder = WebApplication.CreateEmptyBuilder(new WebApplicationOptions());
        builder.WebHost.UseKestrelCore().ConfigureKestrel(kestrel =>
        {
            kestrel.Listen(IPAddress.Loopback, Port);
            kestrel.AddServerHeader = false;
            // The body cap is enforced while reading so the error carries the protocol's JSON body.
            kestrel.Limits.MaxRequestBodySize = null;
        });
        var app = builder.Build();
        Map(app, service);
        return app;
    }

    public static void Map(IApplicationBuilder app, PrintService service) =>
        app.Run(context => HandleAsync(context, service));

    public static bool IsAllowedOrigin(string origin, IEnumerable<string> configured) =>
        BuiltInOrigins.Concat(configured).Any(o => string.Equals(o, origin, StringComparison.OrdinalIgnoreCase));

    private static async Task HandleAsync(HttpContext context, PrintService service)
    {
        var request = context.Request;
        var response = context.Response;
        string origin = request.Headers.Origin.ToString();
        if (origin.Length > 0 && IsAllowedOrigin(origin, service.AllowedOrigins))
        {
            response.Headers.AccessControlAllowOrigin = origin;
            response.Headers.AccessControlAllowMethods = "GET, POST, OPTIONS";
            response.Headers.AccessControlAllowHeaders = "Content-Type";
            response.Headers["Access-Control-Allow-Private-Network"] = "true";
            response.Headers.AccessControlMaxAge = "600";
        }

        try
        {
            string? allowedMethod = request.Path.Value switch
            {
                "/status" or "/printers" => HttpMethods.Get,
                "/print" => HttpMethods.Post,
                _ => throw ApiError.NotFound(),
            };
            if (HttpMethods.IsOptions(request.Method))
            {
                response.StatusCode = StatusCodes.Status204NoContent;
                return;
            }
            if (!string.Equals(request.Method, allowedMethod, StringComparison.OrdinalIgnoreCase))
            {
                throw ApiError.MethodNotAllowed();
            }

            switch (request.Path.Value)
            {
                case "/status":
                    await WriteAsync(response, 200, service.Status(), ProtocolJson.Default.StatusResponse);
                    break;
                case "/printers":
                    await WriteAsync(response, 200, new PrintersResponse(service.Printers()), ProtocolJson.Default.PrintersResponse);
                    break;
                default:
                    await PrintAsync(context, service);
                    break;
            }
        }
        catch (ApiError error)
        {
            if (!response.HasStarted)
            {
                await WriteAsync(response, error.Status, new ErrorResponse(new ErrorDetail(error.Code, error.Message)),
                    ProtocolJson.Default.ErrorResponse);
            }
        }
    }

    private static async Task PrintAsync(HttpContext context, PrintService service)
    {
        var query = context.Request.Query;
        var channel = query["channel"].ToString() switch
        {
            "label" when query["channel"].Count == 1 => Channel.Label,
            "document" when query["channel"].Count == 1 => Channel.Document,
            _ => throw ApiError.BadChannel(),
        };

        int copies = 1;
        if (query.TryGetValue("copies", out var copiesValue) &&
            (copiesValue.Count != 1 ||
             !int.TryParse(copiesValue.ToString(), NumberStyles.None, CultureInfo.InvariantCulture, out copies) ||
             copies is < 1 or > 99))
        {
            throw ApiError.BadCopies();
        }

        if (context.Request.ContentLength > MaxBodyBytes)
        {
            throw ApiError.TooLarge();
        }

        var job = await service.PrintAsync(channel, copies, query["title"].ToString(),
            cancellation => ReadBodyAsync(context.Request, cancellation), context.RequestAborted);
        await WriteAsync(context.Response, 200, new JobResponse(job), ProtocolJson.Default.JobResponse);
    }

    private static async Task<ReadOnlyMemory<byte>> ReadBodyAsync(HttpRequest request, CancellationToken cancellation)
    {
        var body = new MemoryStream((int)(request.ContentLength ?? 0));
        var chunk = new byte[81920];
        int read;
        while ((read = await request.Body.ReadAsync(chunk, cancellation)) > 0)
        {
            if (body.Length + read > MaxBodyBytes)
            {
                throw ApiError.TooLarge();
            }
            body.Write(chunk, 0, read);
        }
        return body.GetBuffer().AsMemory(0, (int)body.Length);
    }

    private static Task WriteAsync<T>(HttpResponse response, int status, T value, JsonTypeInfo<T> type)
    {
        response.StatusCode = status;
        return response.WriteAsJsonAsync(value, type);
    }
}
