using System.Runtime.InteropServices.WindowsRuntime;
using NodePrint.Core;
using Windows.Data.Pdf;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace NodePrint.Printing;

/// <summary>The body of a print request as pages: a PDF, or a PNG or JPEG as one page.</summary>
internal abstract class SourceDocument
{
    private const double PointsPerDip = 72.0 / 96;

    public abstract int PageCount { get; }

    /// <summary>Rows rendered at a time for an unturned page, so a page at a printer's full resolution does not have to
    /// sit in memory whole.</summary>
    public abstract int BandRows { get; }

    /// <summary>A page's visible box in PDF points (1/72 in), after its own rotation.</summary>
    public abstract (double Width, double Height) PageSize(int index);

    /// <summary>Rows <paramref name="top"/> to <paramref name="top"/> + <paramref name="rows"/> of the page drawn at the
    /// placement's size (turned clockwise when it says so), as top-down BGRA on white. In
    /// <paramref name="monochrome"/> every pixel ends up pure black or pure white and images scale by nearest
    /// neighbour, so a label printer gets nothing to smooth or dither.</summary>
    public abstract Task<byte[]> RenderAsync(int index, Placement placement, int top, int rows, bool monochrome);

    public static async Task<SourceDocument> OpenAsync(ReadOnlyMemory<byte> bytes)
    {
        var span = bytes.Span;
        bool pdf = span.StartsWith("%PDF-"u8);
        bool image = span.StartsWith((ReadOnlySpan<byte>)[0x89, (byte)'P', (byte)'N', (byte)'G']) ||
            span.StartsWith((ReadOnlySpan<byte>)[0xFF, 0xD8, 0xFF]);
        if (!pdf && !image) throw ApiError.BadDocument("it is neither a PDF nor a PNG or JPEG image.");
        try
        {
            var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(bytes.ToArray().AsBuffer());
            stream.Seek(0);
            SourceDocument document = pdf
                ? new PdfSource(await PdfDocument.LoadFromStreamAsync(stream))
                : new ImageSource(await BitmapDecoder.CreateAsync(stream));
            return document.PageCount > 0 ? document : throw ApiError.BadDocument("it has no pages.");
        }
        catch (Exception e) when (e is not ApiError)
        {
            throw ApiError.BadDocument(e.Message.Trim());
        }
    }

    private sealed class PdfSource(PdfDocument document) : SourceDocument
    {
        public override int PageCount => (int)document.PageCount;

        public override int BandRows => 512;

        public override (double Width, double Height) PageSize(int index)
        {
            using var page = document.GetPage((uint)index);
            return (page.Size.Width * PointsPerDip, page.Size.Height * PointsPerDip);
        }

        public override async Task<byte[]> RenderAsync(int index, Placement placement, int top, int rows, bool monochrome)
        {
            using var page = document.GetPage((uint)index);
            var options = new PdfPageRenderOptions
            {
                DestinationWidth = (uint)placement.RenderWidth,
                DestinationHeight = (uint)placement.RenderHeight,
                BackgroundColor = new Windows.UI.Color { A = 255, R = 255, G = 255, B = 255 },
                BitmapEncoderId = BitmapEncoder.BmpEncoderId,
            };
            if (!placement.Rotated && (top > 0 || rows < placement.Height))
            {
                double scale = placement.Height / page.Size.Height;
                options.SourceRect = new Windows.Foundation.Rect(0, top / scale, page.Size.Width, rows / scale);
                options.DestinationHeight = (uint)rows;
            }
            using var output = new InMemoryRandomAccessStream();
            await page.RenderToStreamAsync(output, options);
            output.Seek(0);
            var decoder = await BitmapDecoder.CreateAsync(BitmapDecoder.BmpDecoderId, output);
            var transform = new BitmapTransform
            {
                Rotation = placement.Rotated ? BitmapRotation.Clockwise90Degrees : BitmapRotation.None,
            };
            var pixels = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, transform,
                ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage);
            byte[] bgra = pixels.DetachPixelData();
            return monochrome ? Threshold(bgra) : bgra;
        }
    }

    private sealed class ImageSource(BitmapDecoder decoder) : SourceDocument
    {
        public override int PageCount => 1;

        public override int BandRows => int.MaxValue;

        public override (double Width, double Height) PageSize(int index) => (
            decoder.OrientedPixelWidth * 72 / (decoder.DpiX > 0 ? decoder.DpiX : 96),
            decoder.OrientedPixelHeight * 72 / (decoder.DpiY > 0 ? decoder.DpiY : 96));

        public override async Task<byte[]> RenderAsync(int index, Placement placement, int top, int rows, bool monochrome)
        {
            var transform = new BitmapTransform
            {
                ScaledWidth = (uint)placement.RenderWidth,
                ScaledHeight = (uint)placement.RenderHeight,
                InterpolationMode = monochrome ? BitmapInterpolationMode.NearestNeighbor : BitmapInterpolationMode.Fant,
                Rotation = placement.Rotated ? BitmapRotation.Clockwise90Degrees : BitmapRotation.None,
            };
            var pixels = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Straight, transform,
                ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb);
            byte[] bgra = pixels.DetachPixelData();
            // Transparent parts print as paper, not as black.
            for (int i = 0; i < bgra.Length; i += 4)
            {
                int alpha = bgra[i + 3];
                if (alpha == 255) continue;
                for (int c = 0; c < 3; c++) bgra[i + c] = (byte)((bgra[i + c] * alpha + 255 * (255 - alpha)) / 255);
                bgra[i + 3] = 255;
            }
            return monochrome ? Threshold(bgra) : bgra;
        }
    }

    /// <summary>Black below half grey, white from there up; no dithering.</summary>
    private static byte[] Threshold(byte[] bgra)
    {
        for (int i = 0; i < bgra.Length; i += 4)
        {
            byte value = 299 * bgra[i + 2] + 587 * bgra[i + 1] + 114 * bgra[i] < 128_000 ? (byte)0 : (byte)255;
            bgra[i] = bgra[i + 1] = bgra[i + 2] = value;
        }
        return bgra;
    }
}
