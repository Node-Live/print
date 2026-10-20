using NodePrint.Core;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32.Graphics.Printing;

namespace NodePrint.Printing;

internal static unsafe class DevModes
{
    private const uint OutBuffer = 2;
    private const uint InBuffer = 8;

    /// <summary>The driver's own DEVMODE with the paper and orientation set on it and merged back by the driver, so the
    /// job carries the paper instead of the printer's defaults.</summary>
    public static byte[] For(string printerName, Capabilities capabilities, (int Width, int Length) paper, bool landscape) =>
        WithPrinter(printerName, (printer, name) =>
        {
            byte[] buffer = Current(printer, name);
            fixed (byte* bytes = buffer)
            {
                var devmode = (DEVMODEW*)bytes;
                short id = PaperId(capabilities, paper);
                if (id != 0)
                {
                    devmode->dmPaperSize = id;
                    devmode->dmFields |= DEVMODE_FIELD_FLAGS.DM_PAPERSIZE;
                    devmode->dmFields &= ~(DEVMODE_FIELD_FLAGS.DM_PAPERWIDTH | DEVMODE_FIELD_FLAGS.DM_PAPERLENGTH);
                }
                else
                {
                    devmode->dmPaperSize = (short)PInvoke.DMPAPER_USER;
                    devmode->dmPaperWidth = (short)paper.Width;
                    devmode->dmPaperLength = (short)paper.Length;
                    devmode->dmFields |= DEVMODE_FIELD_FLAGS.DM_PAPERSIZE | DEVMODE_FIELD_FLAGS.DM_PAPERWIDTH |
                        DEVMODE_FIELD_FLAGS.DM_PAPERLENGTH;
                }
                devmode->dmOrientation = (short)(landscape ? PInvoke.DMORIENT_LANDSCAPE : PInvoke.DMORIENT_PORTRAIT);
                devmode->dmCopies = 1;
                devmode->dmFields |= DEVMODE_FIELD_FLAGS.DM_ORIENTATION | DEVMODE_FIELD_FLAGS.DM_COPIES;
                if (PInvoke.DocumentProperties(default, printer, name, devmode, devmode, InBuffer | OutBuffer) < 0)
                {
                    throw Spooler.Failure("DocumentProperties");
                }
            }
            return buffer;
        });

    /// <summary>The resolution in the driver's current DEVMODE, 0 when it does not give one.</summary>
    public static int Resolution(string printerName)
    {
        try
        {
            return WithPrinter(printerName, (printer, name) =>
            {
                fixed (byte* bytes = Current(printer, name))
                {
                    var devmode = (DEVMODEW*)bytes;
                    if ((devmode->dmFields & DEVMODE_FIELD_FLAGS.DM_YRESOLUTION) != 0 && devmode->dmYResolution > 0)
                    {
                        return devmode->dmYResolution;
                    }
                    if ((devmode->dmFields & DEVMODE_FIELD_FLAGS.DM_PRINTQUALITY) != 0 && devmode->dmPrintQuality > 0)
                    {
                        return devmode->dmPrintQuality;
                    }
                    return 0;
                }
            });
        }
        catch (IOException)
        {
            return 0;
        }
    }

    private static T WithPrinter<T>(string printerName, Func<PRINTER_HANDLE, PWSTR, T> use)
    {
        PRINTER_HANDLE printer;
        fixed (char* name = printerName)
        {
            if (!PInvoke.OpenPrinter(name, &printer, null)) throw Spooler.Failure("OpenPrinter");
            try
            {
                return use(printer, name);
            }
            finally
            {
                PInvoke.ClosePrinter(printer);
            }
        }
    }

    private static byte[] Current(PRINTER_HANDLE printer, PWSTR name)
    {
        int size = PInvoke.DocumentProperties(default, printer, name, null, null, 0);
        if (size < sizeof(DEVMODEW)) throw Spooler.Failure("DocumentProperties");
        var buffer = new byte[size];
        fixed (byte* bytes = buffer)
        {
            if (PInvoke.DocumentProperties(default, printer, name, (DEVMODEW*)bytes, null, OutBuffer) < 0)
            {
                throw Spooler.Failure("DocumentProperties");
            }
        }
        return buffer;
    }

    /// <summary>The DMPAPER id of the driver's paper that is this size in either orientation, or 0.</summary>
    private static short PaperId(Capabilities capabilities, (int Width, int Length) paper)
    {
        for (int i = 0; i < capabilities.PaperIds.Count; i++)
        {
            if (PrinterRules.Matches(capabilities.PaperSizes[i], paper.Width, paper.Length)) return capabilities.PaperIds[i];
        }
        return 0;
    }
}
