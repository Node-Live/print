using NodePrint.Core;
using Windows.Win32;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32.Storage.Xps;

namespace NodePrint.Printing;

/// <summary>A job through the printer's driver: each page rasterised at the printer's resolution for the printable
/// area and drawn through GDI pixel for pixel, with the paper and orientation set on the job's DEVMODE. Labels go as
/// 1-bit black and white, so the driver has no grey to dither.</summary>
internal static class DriverJob
{
    public static readonly (int Width, int Length) LabelPaper = (1016, 1524);
    public static readonly (int Width, int Length) LetterPaper = (2159, 2794);

    private const double PaperToleranceInches = 0.08;

    public static async Task PrintAsync(Printer printer, Capabilities capabilities, Channel channel,
        SourceDocument document, int copies, string title)
    {
        bool label = channel == Channel.Label;
        var paper = label ? LabelPaper : LetterPaper;
        byte[] portrait = DevModes.For(printer.Id, capabilities, paper, landscape: false);
        byte[]? landscape = label ? null : DevModes.For(printer.Id, capabilities, paper, landscape: true);

        var dc = Gdi.CreateDC(printer.Id, portrait);
        try
        {
            if (label)
            {
                var (width, length) = Gdi.PaperInches(dc);
                if (Math.Abs(width - 4) > PaperToleranceInches || Math.Abs(length - 6) > PaperToleranceInches)
                {
                    throw ApiError.PrintFailed(printer.Name,
                        $"the driver set the paper to {width:0.##} × {length:0.##} in instead of 4 × 6 in.");
                }
            }
            Gdi.StartDoc(dc, title);
            try
            {
                bool turned = false;
                foreach (int index in PageOrder(document.PageCount, copies, label))
                {
                    var (pageWidth, pageHeight) = document.PageSize(index);
                    bool wantLandscape = !label && PageLayout.IsLandscape(pageWidth, pageHeight);
                    if (wantLandscape != turned)
                    {
                        Gdi.Reset(dc, wantLandscape ? landscape! : portrait);
                        turned = wantLandscape;
                    }
                    Gdi.Check(PInvoke.StartPage(dc), "StartPage");
                    var (areaWidth, areaHeight) = Gdi.PrintableArea(dc);
                    var placement = label
                        ? PageLayout.Label(pageWidth, pageHeight, areaWidth, areaHeight)
                        : PageLayout.Document(pageWidth, pageHeight, areaWidth, areaHeight);
                    int band = placement.Rotated ? placement.Height : Math.Min(document.BandRows, placement.Height);
                    for (int top = 0; top < placement.Height; top += band)
                    {
                        int rows = Math.Min(band, placement.Height - top);
                        Gdi.Draw(dc, placement, top, rows, await document.RenderAsync(index, placement, top, rows, label), label);
                    }
                    Gdi.Check(PInvoke.EndPage(dc), "EndPage");
                }
                Gdi.Check(PInvoke.EndDoc(dc), "EndDoc");
            }
            catch
            {
                PInvoke.AbortDoc(dc);
                throw;
            }
        }
        finally
        {
            PInvoke.DeleteDC(dc);
        }
    }

    /// <summary>Labels repeat each page (A A B B); documents repeat the whole document (A B A B).</summary>
    private static IEnumerable<int> PageOrder(int pages, int copies, bool label) => label
        ? Enumerable.Range(0, pages).SelectMany(p => Enumerable.Repeat(p, copies))
        : Enumerable.Range(0, copies).SelectMany(_ => Enumerable.Range(0, pages));

    private static unsafe class Gdi
    {
        public static HDC CreateDC(string printerName, byte[] devmode)
        {
            fixed (char* name = printerName)
            fixed (byte* mode = devmode)
            {
                var dc = PInvoke.CreateDCW(default, name, default, (DEVMODEW*)mode);
                return dc.IsNull ? throw Spooler.Failure("CreateDC") : dc;
            }
        }

        public static void StartDoc(HDC dc, string title)
        {
            fixed (char* name = title)
            {
                var info = new DOCINFOW { cbSize = sizeof(DOCINFOW), lpszDocName = name };
                Check(PInvoke.StartDoc(dc, &info), "StartDoc");
            }
        }

        public static void Reset(HDC dc, byte[] devmode)
        {
            fixed (byte* mode = devmode)
            {
                if (PInvoke.ResetDCW(dc, (DEVMODEW*)mode).IsNull) throw Spooler.Failure("ResetDC");
            }
        }

        /// <summary>The paper the driver actually settled on for this DC.</summary>
        public static (double Width, double Length) PaperInches(HDC dc) => (
            (double)PInvoke.GetDeviceCaps(dc, GET_DEVICE_CAPS_INDEX.PHYSICALWIDTH) / PInvoke.GetDeviceCaps(dc, GET_DEVICE_CAPS_INDEX.LOGPIXELSX),
            (double)PInvoke.GetDeviceCaps(dc, GET_DEVICE_CAPS_INDEX.PHYSICALHEIGHT) / PInvoke.GetDeviceCaps(dc, GET_DEVICE_CAPS_INDEX.LOGPIXELSY));

        public static (int Width, int Height) PrintableArea(HDC dc) =>
            (PInvoke.GetDeviceCaps(dc, GET_DEVICE_CAPS_INDEX.HORZRES), PInvoke.GetDeviceCaps(dc, GET_DEVICE_CAPS_INDEX.VERTRES));

        /// <summary>Draws rows <paramref name="top"/> on of the placed page, rendered 1:1 at device resolution;
        /// <paramref name="monochrome"/> pixels (pure black or white) go as a 1-bit DIB.</summary>
        public static void Draw(HDC dc, Placement placement, int top, int rows, byte[] pixels, bool monochrome)
        {
            // BITMAPINFO has room for one palette entry; the 1-bit DIB needs two.
            byte* info = stackalloc byte[sizeof(BITMAPINFOHEADER) + 2 * sizeof(RGBQUAD)];
            *(BITMAPINFOHEADER*)info = new BITMAPINFOHEADER
            {
                biSize = (uint)sizeof(BITMAPINFOHEADER),
                biWidth = placement.Width,
                biHeight = -rows,
                biPlanes = 1,
                biBitCount = (ushort)(monochrome ? 1 : 32),
                biCompression = (uint)BI_COMPRESSION.BI_RGB,
                biClrUsed = monochrome ? 2u : 0u,
            };
            var palette = (RGBQUAD*)(info + sizeof(BITMAPINFOHEADER));
            palette[0] = default;
            palette[1] = new RGBQUAD { rgbBlue = 255, rgbGreen = 255, rgbRed = 255 };
            fixed (byte* bits = monochrome ? Pack(pixels, placement.Width, rows) : pixels)
            {
                int lines = PInvoke.StretchDIBits(dc, placement.X, placement.Y + top, placement.Width, rows,
                    0, 0, placement.Width, rows, bits, (BITMAPINFO*)info, DIB_USAGE.DIB_RGB_COLORS, ROP_CODE.SRCCOPY);
                if (lines == 0) throw Spooler.Failure("StretchDIBits");
            }
        }

        /// <summary>Black-or-white BGRA as 1-bit rows (white = 1, leftmost pixel in the high bit), each row padded to
        /// 4 bytes.</summary>
        private static byte[] Pack(byte[] bgra, int width, int rows)
        {
            int stride = (width + 31) / 32 * 4;
            var bits = new byte[stride * rows];
            for (int y = 0; y < rows; y++)
            {
                for (int x = 0; x < width; x++)
                {
                    if (bgra[(y * width + x) * 4] != 0) bits[y * stride + (x >> 3)] |= (byte)(0x80 >> (x & 7));
                }
            }
            return bits;
        }

        public static void Check(int result, string call)
        {
            if (result <= 0) throw Spooler.Failure(call);
        }
    }
}
