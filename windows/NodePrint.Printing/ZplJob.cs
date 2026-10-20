using System.Text;
using NodePrint.Core;
using Windows.Data.Pdf;
using Windows.Win32;
using Windows.Win32.Graphics.Printing;

namespace NodePrint.Printing;

/// <summary>Labels for ZPL printers: each page rasterised at the printer's dots and sent as raw ZPL.</summary>
internal static class ZplJob
{
    public static async Task PrintAsync(Printer printer, PdfDocument document, int copies, string title)
    {
        var (width, length) = PageLayout.LabelDots(printer.Dpi);
        var job = new StringBuilder();
        for (uint i = 0; i < document.PageCount; i++)
        {
            using var page = document.GetPage(i);
            var (pageWidth, pageHeight) = Pdf.SizeOf(page);
            var placement = PageLayout.Label(pageWidth, pageHeight, width, length);
            byte[] pixels = await Pdf.RenderAsync(page, placement);
            Zpl.AppendLabel(job, width, length, Zpl.Pack(pixels, placement, width, length), copies);
        }
        SendRaw(printer.Id, title, Encoding.ASCII.GetBytes(job.ToString()));
    }

    public static unsafe void SendRaw(string printerName, string title, ReadOnlySpan<byte> data)
    {
        PRINTER_HANDLE printer;
        fixed (char* name = printerName)
        {
            if (!PInvoke.OpenPrinter(name, &printer, null)) throw Spooler.Failure("OpenPrinter");
        }
        try
        {
            fixed (char* documentName = title, dataType = "RAW")
            {
                var info = new DOC_INFO_1W { pDocName = documentName, pDatatype = dataType };
                if (PInvoke.StartDocPrinter(printer, 1, &info) == 0) throw Spooler.Failure("StartDocPrinter");
            }
            try
            {
                if (!PInvoke.StartPagePrinter(printer)) throw Spooler.Failure("StartPagePrinter");
                uint written;
                fixed (byte* bytes = data)
                {
                    if (!PInvoke.WritePrinter(printer, bytes, (uint)data.Length, &written)) throw Spooler.Failure("WritePrinter");
                }
                if (written != data.Length) throw new IOException($"WritePrinter wrote {written} of {data.Length} bytes.");
                if (!PInvoke.EndPagePrinter(printer)) throw Spooler.Failure("EndPagePrinter");
            }
            finally
            {
                PInvoke.EndDocPrinter(printer);
            }
        }
        finally
        {
            PInvoke.ClosePrinter(printer);
        }
    }
}
