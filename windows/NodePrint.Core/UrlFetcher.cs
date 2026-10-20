using System.Globalization;

namespace NodePrint.Core;

/// <summary>Downloads the document a URL print job names: http or https, redirects followed, 30 s for the whole
/// download, no more than the body limit.</summary>
public static class UrlFetcher
{
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(30);

    private static readonly string TooLarge =
        string.Create(CultureInfo.InvariantCulture, $"it is larger than {LocalApi.MaxBodyBytes:N0} bytes.");

    private static readonly HttpClient Client = new(new SocketsHttpHandler { AllowAutoRedirect = true })
    {
        Timeout = System.Threading.Timeout.InfiniteTimeSpan,
    };

    /// <summary>The URL in a JSON print body, or BAD_URL when it is missing or not http(s).</summary>
    public static Uri Parse(string? url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri) && (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps)
            ? uri
            : throw ApiError.BadUrl();

    public static async Task<ReadOnlyMemory<byte>> FetchAsync(Uri url)
    {
        using var timeout = new CancellationTokenSource(Timeout);
        try
        {
            using var response = await Client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
            if (!response.IsSuccessStatusCode)
            {
                throw ApiError.FetchFailed(url, $"the server answered {(int)response.StatusCode} {response.ReasonPhrase}.");
            }
            if (response.Content.Headers.ContentLength > LocalApi.MaxBodyBytes)
            {
                throw ApiError.FetchFailed(url, TooLarge);
            }
            await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
            var body = new MemoryStream();
            var chunk = new byte[81920];
            int read;
            while ((read = await stream.ReadAsync(chunk, timeout.Token)) > 0)
            {
                if (body.Length + read > LocalApi.MaxBodyBytes)
                {
                    throw ApiError.FetchFailed(url, TooLarge);
                }
                body.Write(chunk, 0, read);
            }
            return body.GetBuffer().AsMemory(0, (int)body.Length);
        }
        catch (OperationCanceledException) when (timeout.IsCancellationRequested)
        {
            throw ApiError.FetchFailed(url, $"no complete answer within {Timeout.TotalSeconds:0} s.");
        }
        catch (HttpRequestException e)
        {
            throw ApiError.FetchFailed(url, e.Message);
        }
        catch (IOException e)
        {
            throw ApiError.FetchFailed(url, e.Message);
        }
    }
}
