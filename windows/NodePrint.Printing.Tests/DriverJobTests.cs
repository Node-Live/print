using System.Diagnostics;
using NodePrint.Core;

namespace NodePrint.Printing.Tests;

/// <summary>Jobs through the driver against the CI's "Microsoft Print to PDF" queues on file ports, checking the pages
/// that land in the file. Skipped where those queues are not set up.</summary>
public sealed class DriverJobTests
{
    private const string LabelQueue = "NODE CI Label";
    private const string DocumentQueue = "NODE CI Document";
    private static readonly string Report = Path.Combine(AppContext.BaseDirectory, "driver-jobs.txt");

    [Fact]
    public async Task A_landscape_label_comes_out_as_one_4_by_6_portrait_page()
    {
        var pages = await PrintAsync(LabelQueue, Channel.Label, Path.Combine("zpl", "corner-landscape-4x6-203.pdf"));

        Assert.Equal([(384.0, 576.0)], pages);
    }

    [Fact]
    public async Task Document_pages_come_out_on_letter_in_their_own_orientation()
    {
        var pages = await PrintAsync(DocumentQueue, Channel.Document, Path.Combine("Fixtures", "letter-mixed.pdf"));

        Assert.Equal([(816.0, 1056.0), (1056.0, 816.0)], pages);
    }

    private static async Task<IReadOnlyList<(double Width, double Height)>> PrintAsync(string queueName, Channel channel,
        string fixture)
    {
        var queue = Spooler.Find(queueName);
        Assert.SkipWhen(queue is null, $"{queueName} is not installed");
        string output = queue!.Port;
        File.Delete(output);
        var capabilities = Spooler.CapabilitiesOf(queue.Name, queue.Port);
        var document = await Pdf.OpenAsync(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, fixture)));

        var clock = Stopwatch.StartNew();
        await Task.Run(() => DriverJob.Print(queue.Name, capabilities, channel, document, 1, fixture));
        var printed = await ReadOutputAsync(output);
        clock.Stop();

        File.Copy(output, Path.Combine(AppContext.BaseDirectory, $"driver-{channel}.pdf".ToLowerInvariant()), true);
        string sizes = string.Join(", ", printed.Select(p => $"{p.Width / 96 * 72:0.#}×{p.Height / 96 * 72:0.#} pt"));
        File.AppendAllText(Report,
            $"{channel}: {printed.Count} page(s) {sizes}; {new FileInfo(output).Length / 1024} KB; {clock.ElapsedMilliseconds} ms\n");
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
