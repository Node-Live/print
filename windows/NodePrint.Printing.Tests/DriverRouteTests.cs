using System.Diagnostics;
using NodePrint.Core;

namespace NodePrint.Printing.Tests;

/// <summary>Both driver routes against the CI's "Microsoft Print to PDF" queues on file ports, checking the pages that
/// land in the file. Skipped where those queues are not set up.</summary>
public sealed class DriverRouteTests
{
    private const string LabelQueue = "NODE CI Label";
    private const string DocumentQueue = "NODE CI Document";
    private static readonly string Report = Path.Combine(AppContext.BaseDirectory, "route-comparison.txt");

    [Theory]
    [InlineData("gdi")]
    [InlineData("xps")]
    public async Task A_landscape_label_comes_out_as_one_4_by_6_portrait_page(string route)
    {
        var pages = await PrintAsync(route, LabelQueue, Channel.Label, Path.Combine("zpl", "corner-landscape-4x6-203.pdf"));

        Assert.Equal([(384.0, 576.0)], pages);
    }

    [Theory]
    [InlineData("gdi")]
    [InlineData("xps")]
    public async Task Document_pages_come_out_on_letter_in_their_own_orientation(string route)
    {
        var pages = await PrintAsync(route, DocumentQueue, Channel.Document, Path.Combine("Fixtures", "letter-mixed.pdf"));

        Assert.Equal([(816.0, 1056.0), (1056.0, 816.0)], pages);
    }

    private static async Task<IReadOnlyList<(double Width, double Height)>> PrintAsync(string route, string queueName,
        Channel channel, string fixture)
    {
        var queue = Spooler.Find(queueName);
        Assert.SkipWhen(queue is null, $"{queueName} is not installed");
        string output = queue!.Port;
        File.Delete(output);
        var capabilities = Spooler.CapabilitiesOf(queue.Name, queue.Port);
        var document = await Pdf.OpenAsync(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, fixture)));

        var clock = Stopwatch.StartNew();
        if (route == "gdi")
        {
            await DriverJob.PrintAsync(queue.Name, capabilities, channel, document, 1, $"{route} {fixture}");
        }
        else
        {
            await Task.Run(() => XpsJob.Print(queue.Name, capabilities, channel, document, 1, $"{route} {fixture}"));
        }
        var printed = await ReadOutputAsync(output);
        clock.Stop();

        File.Copy(output, Path.Combine(AppContext.BaseDirectory, $"{route}-{channel}.pdf".ToLowerInvariant()), true);
        string sizes = string.Join(", ", printed.Select(p => $"{p.Width / 96 * 72:0.#}×{p.Height / 96 * 72:0.#} pt"));
        File.AppendAllText(Report,
            $"{route} {channel}: {printed.Count} page(s) {sizes}; {new FileInfo(output).Length / 1024} KB; {clock.ElapsedMilliseconds} ms\n");
        return [.. printed.Select(p => (Math.Round(p.Width), Math.Round(p.Height)))];
    }

    /// <summary>The spooler writes the file once the job has gone through; read it when it is complete.</summary>
    private static async Task<IReadOnlyList<(double Width, double Height)>> ReadOutputAsync(string path)
    {
        for (var deadline = DateTime.UtcNow.AddSeconds(60); DateTime.UtcNow < deadline; await Task.Delay(250))
        {
            byte[] bytes;
            try
            {
                using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None);
                bytes = new byte[stream.Length];
                stream.ReadExactly(bytes);
            }
            catch (IOException)
            {
                continue;
            }
            if (bytes.Length == 0) continue;
            Windows.Data.Pdf.PdfDocument document;
            try
            {
                document = await Pdf.OpenAsync(bytes);
            }
            catch (ApiError)
            {
                continue;
            }
            var pages = new List<(double, double)>();
            for (uint i = 0; i < document.PageCount; i++)
            {
                using var page = document.GetPage(i);
                pages.Add(Pdf.SizeOf(page));
            }
            return pages;
        }
        throw new TimeoutException($"{path} was not written");
    }
}
