using System.Runtime.InteropServices.WindowsRuntime;
using NodePrint.Core;
using Windows.Data.Pdf;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace NodePrint.Printing;

internal static class Pdf
{
    public static async Task<PdfDocument> OpenAsync(ReadOnlyMemory<byte> bytes)
    {
        PdfDocument document;
        try
        {
            using var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(bytes.ToArray().AsBuffer());
            stream.Seek(0);
            document = await PdfDocument.LoadFromStreamAsync(stream);
        }
        catch (Exception e)
        {
            throw ApiError.BadDocument(e.Message.Trim());
        }
        if (document.PageCount == 0) throw ApiError.BadDocument("it has no pages.");
        return document;
    }

    /// <summary>The page as it is shown (its own rotation applied), in DIPs.</summary>
    public static (double Width, double Height) SizeOf(PdfPage page) => (page.Size.Width, page.Size.Height);

    /// <summary>Renders the page at the placement's size, turned clockwise when the placement says so, as top-down
    /// BGRA rows of <see cref="Placement.Width"/> pixels on white.</summary>
    public static async Task<byte[]> RenderAsync(PdfPage page, Placement placement)
    {
        using var output = new InMemoryRandomAccessStream();
        await page.RenderToStreamAsync(output, new PdfPageRenderOptions
        {
            DestinationWidth = (uint)placement.RenderWidth,
            DestinationHeight = (uint)placement.RenderHeight,
            BackgroundColor = new Windows.UI.Color { A = 255, R = 255, G = 255, B = 255 },
            BitmapEncoderId = BitmapEncoder.BmpEncoderId,
        });
        output.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(BitmapDecoder.BmpDecoderId, output);
        var transform = new BitmapTransform
        {
            Rotation = placement.Rotated ? BitmapRotation.Clockwise90Degrees : BitmapRotation.None,
        };
        var pixels = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, transform,
            ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage);
        return pixels.DetachPixelData();
    }
}
