using System.Text.Json;
using NodePrint.Core;

namespace NodePrint.Printing.Tests;

/// <summary>The shared page vectors: a label PDF rendered by Windows.Data.Pdf must give the vector's bitmap exactly.</summary>
public sealed class LabelPageTests
{
    private static readonly string Folder = Path.Combine(AppContext.BaseDirectory, "zpl");

    public static TheoryData<string> Pages() =>
        [.. Directory.GetFiles(Folder, "*.pdf").Select(f => Path.GetFileNameWithoutExtension(f)).Order()];

    [Theory]
    [MemberData(nameof(Pages))]
    public async Task Renders_the_label_page_to_the_vector_bitmap(string name)
    {
        using var json = JsonDocument.Parse(File.ReadAllText(Path.Combine(Folder, name + ".json")));
        var vector = json.RootElement;
        int width = vector.GetProperty("width").GetInt32(), length = vector.GetProperty("length").GetInt32();
        string[] rows = [.. vector.GetProperty("rows").EnumerateArray().Select(r => r.GetString()!)];
        var document = await Pdf.OpenAsync(File.ReadAllBytes(Path.Combine(Folder, name + ".pdf")));
        using var page = document.GetPage(0);
        var (pageWidth, pageHeight) = Pdf.SizeOf(page);
        var placement = PageLayout.Label(pageWidth, pageHeight, width, length);

        byte[] packed = Zpl.Pack(await Pdf.RenderAsync(page, placement), placement, width, length);

        int bytesPerRow = (width + 7) / 8;
        var wrong = Enumerable.Range(0, length)
            .Where(y => Convert.ToHexString(packed, y * bytesPerRow, bytesPerRow) != rows[y]).ToList();
        Assert.True(wrong.Count == 0, $"{wrong.Count} rows differ, first at {wrong.FirstOrDefault()}");
        Assert.Equal(vector.GetProperty("data").GetString(), Zpl.Compress(packed, bytesPerRow));
    }

    [Fact]
    public async Task A_body_that_is_not_a_pdf_is_a_bad_document()
    {
        var error = await Assert.ThrowsAsync<ApiError>(() => Pdf.OpenAsync("hello"u8.ToArray()));

        Assert.Equal("BAD_DOCUMENT", error.Code);
    }
}
