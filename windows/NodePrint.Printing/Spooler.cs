using System.ComponentModel;
using System.Runtime.InteropServices;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Printing;
using Windows.Win32.Storage.Xps;

namespace NodePrint.Printing;

/// <summary>A print queue as PRINTER_INFO_2 describes it.</summary>
internal sealed record Queue(string Name, string Driver, string Port, uint Status, uint Attributes, uint Jobs);

/// <summary>The driver's paper sizes (0.1 mm, with the matching DMPAPER ids) and its current resolution (0 when it
/// does not say).</summary>
internal sealed record Capabilities(IReadOnlyList<(int Width, int Length)> PaperSizes, IReadOnlyList<short> PaperIds, int Dpi);

internal static unsafe class Spooler
{
    public static IReadOnlyList<Queue> Queues()
    {
        var queues = new List<Queue>();
        Fill((buffer, size, needed, returned) => PInvoke.EnumPrinters(
            PInvoke.PRINTER_ENUM_LOCAL | PInvoke.PRINTER_ENUM_CONNECTIONS, default, 2, buffer, size, needed, returned),
            (buffer, count) =>
            {
                var infos = (PRINTER_INFO_2W*)buffer;
                for (int i = 0; i < count; i++) queues.Add(ToQueue(infos[i]));
            });
        return queues;
    }

    public static Queue? Find(string name)
    {
        PRINTER_HANDLE opened;
        fixed (char* printerName = name)
        {
            if (!PInvoke.OpenPrinter(printerName, &opened, null)) return null;
        }
        var handle = opened;
        try
        {
            Queue? queue = null;
            Fill((buffer, size, needed, _) => PInvoke.GetPrinter(handle, 2, buffer, size, needed),
                (buffer, _) => queue = ToQueue(*(PRINTER_INFO_2W*)buffer));
            return queue;
        }
        catch (IOException)
        {
            return null;
        }
        finally
        {
            PInvoke.ClosePrinter(handle);
        }
    }

    /// <summary>Port name to its monitor and description, which tell USB, network and Bluetooth ports apart.</summary>
    public static IReadOnlyDictionary<string, string> PortMonitors()
    {
        var ports = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        Fill((buffer, size, needed, returned) => PInvoke.EnumPorts(default, 2, buffer, size, needed, returned),
            (buffer, count) =>
            {
                var infos = (PORT_INFO_2W*)buffer;
                for (int i = 0; i < count; i++)
                {
                    ports[infos[i].pPortName.ToString()] = $"{infos[i].pMonitorName} {infos[i].pDescription}";
                }
            });
        return ports;
    }

    public static string DefaultPrinterName()
    {
        uint length = 0;
        PInvoke.GetDefaultPrinter(default, &length);
        if (length == 0) return "";
        char* name = stackalloc char[(int)length];
        return PInvoke.GetDefaultPrinter(name, &length) ? new string(name) : "";
    }

    public static Capabilities CapabilitiesOf(string name, string port)
    {
        var sizes = Read<System.Drawing.Point>(name, port, PRINTER_DEVICE_CAPABILITIES.DC_PAPERSIZE);
        var ids = Read<short>(name, port, PRINTER_DEVICE_CAPABILITIES.DC_PAPERS);
        return new Capabilities([.. sizes.Select(p => (p.X, p.Y))], ids.Length == sizes.Length ? ids : [], DevModes.Resolution(name));
    }

    /// <summary>The error for a failed call; several winspool and GDI calls set no last error, so there may be no text.</summary>
    public static Exception Failure(string call)
    {
        int code = Marshal.GetLastPInvokeError();
        return new IOException(code == 0 ? $"{call} failed." : $"{call}: {new Win32Exception(code).Message}");
    }

    private static T[] Read<T>(string name, string port, PRINTER_DEVICE_CAPABILITIES capability) where T : unmanaged
    {
        fixed (char* device = name, portName = port)
        {
            int count = PInvoke.DeviceCapabilities(device, portName, capability, default, null);
            if (count <= 0) return [];
            var items = new T[count];
            fixed (T* output = items)
            {
                return PInvoke.DeviceCapabilities(device, portName, capability, (char*)output, null) == count ? items : [];
            }
        }
    }

    private static Queue ToQueue(in PRINTER_INFO_2W info) => new(
        info.pPrinterName.ToString(),
        info.pDriverName.ToString() ?? "",
        info.pPortName.ToString()?.Split(',')[0].Trim() ?? "",
        info.Status,
        info.Attributes,
        info.cJobs);

    private delegate BOOL Call(byte* buffer, uint size, uint* needed, uint* returned);

    /// <summary>The two-call winspool pattern: ask for the size, then fill a buffer read while it is pinned. The size is
    /// asked again when the list grew in between.</summary>
    private static void Fill(Call call, Action<nint, int> read)
    {
        uint needed = 0, returned = 0;
        byte[] buffer = new byte[1];
        for (int attempt = 0; attempt < 3; attempt++)
        {
            fixed (byte* pointer = buffer)
            {
                if (call(pointer, (uint)buffer.Length, &needed, &returned))
                {
                    read((nint)pointer, (int)returned);
                    return;
                }
            }
            if (needed <= buffer.Length) break;
            buffer = new byte[needed];
        }
        throw Failure("winspool");
    }
}
