using System.Runtime.InteropServices;
using System.Runtime.InteropServices.Marshalling;
using NodePrint.Core;
using Windows.Data.Pdf;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Direct2D;
using Windows.Win32.Graphics.Direct2D.Common;
using Windows.Win32.Graphics.Direct3D;
using Windows.Win32.Graphics.Direct3D11;
using Windows.Win32.Graphics.Dxgi;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32.Graphics.Imaging;
using Windows.Win32.Graphics.Printing.PrintTicket;
using Windows.Win32.Storage.Xps.Printing;
using Windows.Win32.System.Com;
using Windows.Win32.System.WinRT.Pdf;

namespace NodePrint.Printing;

/// <summary>Printers without ZPL, the vector way: each page drawn by the PDF renderer into a Direct2D print control,
/// which writes an XPS job with a PrintTicket made from the same DEVMODE.</summary>
internal static unsafe class XpsJob
{
    private const double Dip = 96;

    public static void Print(string printerName, Capabilities capabilities, Channel channel, PdfDocument document,
        int copies, string title)
    {
        PInvoke.CoInitializeEx(null, COINIT.COINIT_MULTITHREADED);
        bool label = channel == Channel.Label;
        var paper = label ? DriverJob.LabelPaper : DriverJob.LetterPaper;
        byte[] portrait = DevModes.For(printerName, capabilities, paper, landscape: false);
        byte[]? landscape = label ? null : DevModes.For(printerName, capabilities, paper, landscape: true);
        var portraitSheet = Sheet.Of(printerName, portrait);
        var landscapeSheet = landscape is null ? portraitSheet : Sheet.Of(printerName, landscape);
        IStream jobTicket = Ticket(printerName, portrait, EPrintTicketScope.kPTJobScope);
        IStream? landscapeTicket = landscape is null ? null : Ticket(printerName, landscape, EPrintTicketScope.kPTPageScope);
        IStream portraitTicket = Ticket(printerName, portrait, EPrintTicketScope.kPTPageScope);

        var dxgi = (IDXGIDevice)CreateDevice();
        Check(PInvoke.D2D1CreateFactory(D2D1_FACTORY_TYPE.D2D1_FACTORY_TYPE_SINGLE_THREADED, typeof(ID2D1Factory1).GUID,
            null, out object factoryObject));
        var factory = (ID2D1Factory1)factoryObject;
        factory.CreateDevice(dxgi, out ID2D1Device device);
        device.CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS.D2D1_DEVICE_CONTEXT_OPTIONS_NONE, out ID2D1DeviceContext context);
        Check(PInvoke.CoCreateInstance(PInvoke.CLSID_WICImagingFactory, null, CLSCTX.CLSCTX_INPROC_SERVER,
            out IWICImagingFactory wic));
        Check(PInvoke.CoCreateInstance(typeof(PrintDocumentPackageTargetFactory).GUID, null, CLSCTX.CLSCTX_INPROC_SERVER,
            out IPrintDocumentPackageTargetFactory targets));
        IPrintDocumentPackageTarget target;
        fixed (char* name = printerName, job = title)
        {
            targets.CreateDocumentPackageTargetForPrintJob(name, job, null!, jobTicket, out target);
        }
        var properties = new D2D1_PRINT_CONTROL_PROPERTIES
        {
            fontSubset = D2D1_PRINT_FONT_SUBSET_MODE.D2D1_PRINT_FONT_SUBSET_MODE_DEFAULT,
            rasterDPI = 300,
            colorSpace = D2D1_COLOR_SPACE.D2D1_COLOR_SPACE_SRGB,
        };
        device.CreatePrintControl(wic, target, &properties, out ID2D1PrintControl control);
        Check(PInvoke.PdfCreateRenderer(dxgi, out IPdfRendererNative renderer));

        var order = label
            ? Enumerable.Range(0, (int)document.PageCount).SelectMany(p => Enumerable.Repeat((uint)p, copies))
            : Enumerable.Range(0, copies).SelectMany(_ => Enumerable.Range(0, (int)document.PageCount).Select(p => (uint)p));
        foreach (uint index in order)
        {
            using var page = document.GetPage(index);
            var (width, height) = Pdf.SizeOf(page);
            bool turned = !label && PageLayout.IsLandscape(width, height);
            var sheet = turned ? landscapeSheet : portraitSheet;
            // Lay out in hundredths of a DIP so the integer placement keeps sub-DIP precision.
            var placement = label
                ? PageLayout.Label(width, height, sheet.AreaWidth * 100, sheet.AreaHeight * 100)
                : PageLayout.Document(width, height, sheet.AreaWidth * 100, sheet.AreaHeight * 100);

            context.CreateCommandList(out ID2D1CommandList list);
            context.SetTarget(list);
            context.BeginDraw();
            var transform = Transform(placement, sheet);
            context.SetTransform(&transform);
            var parameters = new PDF_RENDER_PARAMS
            {
                SourceRect = new D2D_RECT_F { left = 0, top = 0, right = (float)width, bottom = (float)height },
                DestinationWidth = (uint)Math.Round(placement.RenderWidth / 100.0),
                DestinationHeight = (uint)Math.Round(placement.RenderHeight / 100.0),
                BackgroundColor = new D2D_COLOR_F { r = 1, g = 1, b = 1, a = 1 },
                IgnoreHighContrast = true,
            };
            renderer.RenderPageToDeviceContext(((WinRT.IWinRTObject)page).NativeObject.ThisPtr, context, &parameters);
            Check(context.EndDraw(null, null));
            list.Close();
            control.AddPage(list, new D2D_SIZE_F { width = sheet.PageWidth, height = sheet.PageHeight },
                turned ? landscapeTicket : portraitTicket, null, null);
        }
        control.Close();
    }

    /// <summary>Turns a landscape label page clockwise, then moves it to its place in the printable area.</summary>
    private static D2D_MATRIX_3X2_F Transform(Placement placement, Sheet sheet)
    {
        float left = sheet.AreaLeft + placement.X / 100f, top = sheet.AreaTop + placement.Y / 100f;
        var matrix = new D2D_MATRIX_3X2_F();
        if (placement.Rotated)
        {
            // (x, y) → (renderHeight − y, x): the page's top edge becomes the right edge.
            matrix.m11 = 0; matrix.m12 = 1; matrix.m21 = -1; matrix.m22 = 0;
            matrix.dx = left + placement.RenderHeight / 100f;
            matrix.dy = top;
        }
        else
        {
            matrix.m11 = 1; matrix.m12 = 0; matrix.m21 = 0; matrix.m22 = 1;
            matrix.dx = left;
            matrix.dy = top;
        }
        return matrix;
    }

    private static ID3D11Device CreateDevice()
    {
        // Runners and remote sessions have no GPU; WARP draws the same command lists in software.
        foreach (var driver in new[] { D3D_DRIVER_TYPE.D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE.D3D_DRIVER_TYPE_WARP })
        {
            var result = PInvoke.D3D11CreateDevice(null, driver, default, D3D11_CREATE_DEVICE_FLAG.D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                null, 0, PInvoke.D3D11_SDK_VERSION, out ID3D11Device device, null, out _);
            if (result.Succeeded) return device;
        }
        throw new IOException("Direct3D is not available.");
    }

    private static IStream Ticket(string printerName, byte[] devmode, EPrintTicketScope scope)
    {
        Check(PInvoke.CreateStreamOnHGlobal(default, true, out IStream stream));
        HPTPROVIDER provider;
        fixed (char* name = printerName)
        {
            Check(PInvoke.PTOpenProvider(name, 1, &provider));
        }
        try
        {
            fixed (byte* mode = devmode)
            {
                Check(PInvoke.PTConvertDevModeToPrintTicket(provider, (uint)devmode.Length, (DEVMODEA*)mode, scope, stream));
            }
        }
        finally
        {
            PInvoke.PTCloseProvider(provider);
        }
        stream.Seek(0, SeekOrigin.Begin);
        return stream;
    }

    private static void Check(HRESULT result)
    {
        if (result.Failed) throw Marshal.GetExceptionForHR(result.Value)!;
    }

    /// <summary>A sheet of paper and its printable area, in DIPs.</summary>
    private sealed record Sheet(float PageWidth, float PageHeight, float AreaLeft, float AreaTop, int AreaWidth, int AreaHeight)
    {
        public static Sheet Of(string printerName, byte[] devmode)
        {
            HDC dc;
            fixed (char* name = printerName)
            fixed (byte* mode = devmode)
            {
                dc = PInvoke.CreateICW(default, name, default, (DEVMODEW*)mode);
            }
            if (dc.IsNull) throw Spooler.Failure("CreateIC");
            try
            {
                double x = PInvoke.GetDeviceCaps(dc, GET_DEVICE_CAPS_INDEX.LOGPIXELSX) / Dip;
                double y = PInvoke.GetDeviceCaps(dc, GET_DEVICE_CAPS_INDEX.LOGPIXELSY) / Dip;
                return new Sheet(
                    (float)(PInvoke.GetDeviceCaps(dc, GET_DEVICE_CAPS_INDEX.PHYSICALWIDTH) / x),
                    (float)(PInvoke.GetDeviceCaps(dc, GET_DEVICE_CAPS_INDEX.PHYSICALHEIGHT) / y),
                    (float)(PInvoke.GetDeviceCaps(dc, GET_DEVICE_CAPS_INDEX.PHYSICALOFFSETX) / x),
                    (float)(PInvoke.GetDeviceCaps(dc, GET_DEVICE_CAPS_INDEX.PHYSICALOFFSETY) / y),
                    (int)(PInvoke.GetDeviceCaps(dc, GET_DEVICE_CAPS_INDEX.HORZRES) / x),
                    (int)(PInvoke.GetDeviceCaps(dc, GET_DEVICE_CAPS_INDEX.VERTRES) / y));
            }
            finally
            {
                PInvoke.DeleteDC(dc);
            }
        }
    }
}
