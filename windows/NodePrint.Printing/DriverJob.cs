using NodePrint.Core;
using Windows.Data.Pdf;
using Windows.Win32;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32.Storage.Xps;

namespace NodePrint.Printing;

/// <summary>Printers without ZPL: each page rasterised for the printable area and drawn through GDI, with the paper and
/// orientation set on the job's DEVMODE.</summary>
internal static class DriverJob
{
    public static readonly (int Width, int Length) LabelPaper = (1016, 1524);
    public static readonly (int Width, int Length) LetterPaper = (2159, 2794);

    // Past this the bitmap only grows the spool file; drivers scale it up to their own resolution.
    private const int RenderDpiLimit = 300;

    public static async Task PrintAsync(string printerName, Capabilities capabilities, Channel channel,
        PdfDocument document, int copies, string title)
    {
        bool label = channel == Channel.Label;
        var paper = label ? LabelPaper : LetterPaper;
        byte[] portrait = DevModes.For(printerName, capabilities, paper, landscape: false);
        byte[]? landscape = label ? null : DevModes.For(printerName, capabilities, paper, landscape: true);

        var dc = Gdi.CreateDC(printerName, portrait);
        try
        {
            Gdi.StartDoc(dc, title);
            try
            {
                bool turned = false;
                foreach (uint index in PageOrder(document.PageCount, copies, label))
                {
                    using var page = document.GetPage(index);
                    var (width, height) = Pdf.SizeOf(page);
                    bool wantLandscape = !label && PageLayout.IsLandscape(width, height);
                    if (wantLandscape != turned)
                    {
                        Gdi.Reset(dc, wantLandscape ? landscape! : portrait);
                        turned = wantLandscape;
                    }
                    Gdi.Check(PInvoke.StartPage(dc), "StartPage");
                    var (area, dpi) = Gdi.PrintableArea(dc);
                    var placement = label
                        ? PageLayout.Label(width, height, area.Width, area.Height)
                        : PageLayout.Document(width, height, area.Width, area.Height);
                    double scale = dpi > RenderDpiLimit ? (double)RenderDpiLimit / dpi : 1;
                    var render = placement with
                    {
                        Width = Math.Max(1, (int)Math.Round(placement.Width * scale)),
                        Height = Math.Max(1, (int)Math.Round(placement.Height * scale)),
                    };
                    Gdi.Draw(dc, placement, render, await Pdf.RenderAsync(page, render));
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

    /// <summary>Labels repeat each page (as ZPL's ^PQ does); documents repeat the whole document.</summary>
    private static IEnumerable<uint> PageOrder(uint pages, int copies, bool label) => label
        ? Enumerable.Range(0, (int)pages).SelectMany(p => Enumerable.Repeat((uint)p, copies))
        : Enumerable.Range(0, copies).SelectMany(_ => Enumerable.Range(0, (int)pages).Select(p => (uint)p));

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

        public static ((int Width, int Height) Area, int Dpi) PrintableArea(HDC dc) => (
            (PInvoke.GetDeviceCaps(dc, GET_DEVICE_CAPS_INDEX.HORZRES), PInvoke.GetDeviceCaps(dc, GET_DEVICE_CAPS_INDEX.VERTRES)),
            PInvoke.GetDeviceCaps(dc, GET_DEVICE_CAPS_INDEX.LOGPIXELSY));

        public static void Draw(HDC dc, Placement placement, Placement render, byte[] pixels)
        {
            var bitmap = new BITMAPINFO
            {
                bmiHeader = new BITMAPINFOHEADER
                {
                    biSize = (uint)sizeof(BITMAPINFOHEADER),
                    biWidth = render.Width,
                    biHeight = -render.Height,
                    biPlanes = 1,
                    biBitCount = 32,
                    biCompression = (uint)BI_COMPRESSION.BI_RGB,
                },
            };
            fixed (byte* bits = pixels)
            {
                int lines = PInvoke.StretchDIBits(dc, placement.X, placement.Y, placement.Width, placement.Height,
                    0, 0, render.Width, render.Height, bits, &bitmap, DIB_USAGE.DIB_RGB_COLORS, ROP_CODE.SRCCOPY);
                if (lines == 0) throw Spooler.Failure("StretchDIBits");
            }
        }

        public static void Check(int result, string call)
        {
            if (result <= 0) throw Spooler.Failure(call);
        }
    }
}
