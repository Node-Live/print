using System.Diagnostics;
using NodePrint.Core;

namespace NodePrint.Printing.Tests;

/// <summary>Jobs through the driver against the CI's "Microsoft Print to PDF" queues on file ports: the pages that
/// land in the file must have the right size, and a corner mark must end up in the right corner. Skipped where those
/// queues are not set up.</summary>
public sealed class DriverJobTests
{
    private const string LabelQueue = "NODE CI Label";
    private const string DocumentQueue = "NODE CI Document";
    private static readonly string Report = Path.Combine(AppContext.BaseDirectory, "driver-jobs.txt");

    [Fact]
    public async Task A_landscape_label_page_turns_clockwise_onto_4_by_6()
    {
        var pages = await PrintAsync(LabelQueue, Channel.Label, Path.Combine("zpl", "corner-landscape-4x6-203.pdf"), 1);

        var page = Assert.Single(pages);
        Assert.Equal((288.0, 432.0), page.Size);
        Assert.Equal(Corner.TopRight, page.Mark);
    }

    [Fact]
    public async Task A_transparent_landscape_png_label_turns_and_prints_its_background_as_paper()
    {
        var pages = await PrintAsync(LabelQueue, Channel.Label, Path.Combine("Fixtures", "label-landscape.png"), 1);

        var page = Assert.Single(pages);
        Assert.Equal((288.0, 432.0), page.Size);
        Assert.Equal(Corner.TopRight, page.Mark);
    }

    [Fact]
    public async Task Label_copies_repeat_each_page_and_document_copies_repeat_the_document()
    {
        var labels = await PrintAsync(LabelQueue, Channel.Label, Path.Combine("zpl", "corner-landscape-4x6-203.pdf"), 2);
        var documents = await PrintAsync(DocumentQueue, Channel.Document, Path.Combine("Fixtures", "letter-mixed.pdf"), 2);

        Assert.Equal(2, labels.Count);
        Assert.Equal([(612.0, 792.0), (792.0, 612.0), (612.0, 792.0), (792.0, 612.0)], documents.Select(p => p.Size));
    }

    [Fact]
    public async Task Document_pages_come_out_on_letter_in_their_own_orientation()
    {
        var pages = await PrintAsync(DocumentQueue, Channel.Document, Path.Combine("Fixtures", "letter-mixed.pdf"), 1);

        Assert.Equal([(612.0, 792.0), (792.0, 612.0)], pages.Select(p => p.Size));
        Assert.All(pages, p => Assert.Equal(Corner.TopLeft, p.Mark));
    }

    [Fact]
    public async Task Pages_are_cut_to_their_crop_box_and_turned_by_their_rotate_entry()
    {
        // Both pages are black outside an offset crop box and carry the mark in the crop box's own top-left: the label
        // is a 6 x 4 in crop under /Rotate 270, the document a portrait Letter crop under /Rotate 90.
        var label = Assert.Single(await PrintAsync(LabelQueue, Channel.Label,
            Path.Combine("Fixtures", "label-cropped-rotated.pdf"), 1));
        var document = Assert.Single(await PrintAsync(DocumentQueue, Channel.Document,
            Path.Combine("Fixtures", "letter-cropped-rotated.pdf"), 1));

        Assert.Equal(((288.0, 432.0), Corner.BottomLeft, false), (label.Size, label.Mark, label.InkOnEdges));
        Assert.Equal(((792.0, 612.0), Corner.TopRight, false), (document.Size, document.Mark, document.InkOnEdges));
    }

    private enum Corner { None, TopLeft, TopRight, BottomLeft, BottomRight, Several }

    private sealed record OutputPage((double Width, double Height) Size, Corner Mark, bool InkOnEdges);

    private static async Task<IReadOnlyList<OutputPage>> PrintAsync(string queueName, Channel channel, string fixture, int copies)
    {
        var queue = Spooler.Find(queueName);
        Assert.SkipWhen(queue is null, $"{queueName} is not installed");
        string output = queue!.Port;
        File.Delete(output);
        var backend = new WindowsPrintBackend();
        var printer = backend.FindPrinter(queueName)!;

        var clock = Stopwatch.StartNew();
        await backend.PrintAsync(printer, channel, File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, fixture)), copies,
            fixture);
        var pages = await ReadOutputAsync(output);
        clock.Stop();

        string name = $"driver-{channel}-{Path.GetFileNameWithoutExtension(fixture)}-x{copies}".ToLowerInvariant();
        File.Copy(output, Path.Combine(AppContext.BaseDirectory, name + ".pdf"), true);
        File.AppendAllText(Report, $"{name}: {string.Join(", ", pages.Select(p => $"{p.Size.Width}×{p.Size.Height} pt {p.Mark}"))}; " +
            $"{new FileInfo(output).Length / 1024} KB; {clock.ElapsedMilliseconds} ms\n");
        return pages;
    }

    /// <summary>The spooler writes the file once the job has gone through; read it when it is complete.</summary>
    private static async Task<IReadOnlyList<OutputPage>> ReadOutputAsync(string path)
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
            SourceDocument document;
            try
            {
                document = await SourceDocument.OpenAsync(bytes);
            }
            catch (ApiError)
            {
                continue;
            }
            var pages = new List<OutputPage>();
            for (int i = 0; i < document.PageCount; i++)
            {
                var (width, height) = document.PageSize(i);
                var (mark, inkOnEdges) = await LookAsync(document, i, width, height);
                pages.Add(new OutputPage((Math.Round(width), Math.Round(height)), mark, inkOnEdges));
            }
            return pages;
        }
        throw new TimeoutException($"{path} was not written");
    }

    /// <summary>Which corner holds the solid mark: a point 0.6 in from each corner (inside the 1 in mark, clear of the
    /// frame and the diagonal) is dark only in that one. Also whether anything is drawn just inside the middle of an
    /// edge.</summary>
    private static async Task<(Corner Mark, bool InkOnEdges)> LookAsync(SourceDocument document, int index, double width, double height)
    {
        int w = (int)Math.Round(width / 2), h = (int)Math.Round(height / 2); // 36 px per inch
        byte[] pixels = await document.RenderAsync(index, new Placement(0, 0, w, h, false), 0, h);
        bool Dark(int x, int y) => 299 * pixels[(y * w + x) * 4 + 2] + 587 * pixels[(y * w + x) * 4 + 1] + 114 * pixels[(y * w + x) * 4] < 100_000;
        var dark = new[]
        {
            (Corner.TopLeft, Dark(22, 22)), (Corner.TopRight, Dark(w - 23, 22)),
            (Corner.BottomLeft, Dark(22, h - 23)), (Corner.BottomRight, Dark(w - 23, h - 23)),
        }.Where(c => c.Item2).Select(c => c.Item1).ToList();
        bool inkOnEdges = Dark(w / 2, 3) || Dark(3, h / 2) || Dark(w - 4, h / 2) || Dark(w / 2, h - 4);
        return (dark.Count switch { 0 => Corner.None, 1 => dark[0], _ => Corner.Several }, inkOnEdges);
    }
}
