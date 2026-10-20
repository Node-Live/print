using System.Text.RegularExpressions;

namespace NodePrint.Core;

/// <summary>How a Windows print queue, as winspool describes it, maps onto the protocol's printer fields.</summary>
public static partial class PrinterRules
{
    private const int LabelShortSideMax = 1181; // 4.65 in, in the 0.1 mm units DeviceCapabilities reports
    private const int PaperTolerance = 10;

    private static readonly string[] HiddenPorts = ["PORTPROMPT:", "FILE:", "NUL", "SHRFAX:"];

    public static bool IsZpl(string driverName) =>
        (driverName.StartsWith("ZDesigner", StringComparison.Ordinal) && !driverName.Contains("(EPL)", StringComparison.Ordinal)) ||
        driverName.Contains("ZPL", StringComparison.Ordinal);

    /// <summary>Queues that open a dialog or write a file instead of reaching a printer.</summary>
    public static bool IsHidden(string portName, string driverName) =>
        HiddenPorts.Any(p => portName.StartsWith(p, StringComparison.OrdinalIgnoreCase)) ||
        string.Equals(driverName, "Microsoft Software Printer Driver", StringComparison.OrdinalIgnoreCase);

    public static Connection ConnectionOf(string portName, string monitorName, bool sharedConnection)
    {
        if (sharedConnection) return Connection.Network;
        if (portName.StartsWith("USB", StringComparison.OrdinalIgnoreCase)) return Connection.Usb;
        if (portName.StartsWith("BTH", StringComparison.OrdinalIgnoreCase) ||
            monitorName.Contains("Bluetooth", StringComparison.OrdinalIgnoreCase)) return Connection.Bluetooth;
        if (portName.StartsWith("WSD", StringComparison.OrdinalIgnoreCase) ||
            portName.StartsWith("IP_", StringComparison.OrdinalIgnoreCase) ||
            portName.Contains("://", StringComparison.Ordinal) ||
            IPv4Prefix().IsMatch(portName) ||
            monitorName.Contains("TCP/IP", StringComparison.OrdinalIgnoreCase) ||
            monitorName.Contains("WSD", StringComparison.OrdinalIgnoreCase) ||
            monitorName.Contains("Internet", StringComparison.OrdinalIgnoreCase) ||
            monitorName.Contains("IPP", StringComparison.OrdinalIgnoreCase)) return Connection.Network;
        if (monitorName.Contains("USB", StringComparison.OrdinalIgnoreCase)) return Connection.Usb;
        return Connection.Other;
    }

    /// <summary>Which protocol papers are among the driver's paper sizes (width, length in 0.1 mm).</summary>
    public static IReadOnlyList<string> PapersOf(IReadOnlyCollection<(int Width, int Length)> sizes)
    {
        var papers = new List<string>();
        if (sizes.Any(s => Matches(s, 1016, 1524))) papers.Add(Papers.FourBySix);
        if (sizes.Any(s => Matches(s, 2159, 2794))) papers.Add(Papers.Letter);
        if (sizes.Any(s => Matches(s, 2100, 2970))) papers.Add(Papers.A4);
        return papers;
    }

    /// <summary>A ZPL queue, or one whose largest paper is no wider than a label.</summary>
    public static PrinterKind KindOf(bool zpl, IReadOnlyCollection<(int Width, int Length)> sizes)
    {
        if (zpl) return PrinterKind.Thermal;
        if (sizes.Count == 0) return PrinterKind.Other;
        var largest = sizes.MaxBy(s => (long)s.Width * s.Length);
        return Math.Min(largest.Width, largest.Length) <= LabelShortSideMax ? PrinterKind.Thermal : PrinterKind.Other;
    }

    public static int DpiOf(bool zpl, IReadOnlyCollection<int> resolutions)
    {
        int reported = resolutions.Count == 0 ? 0 : resolutions.Max();
        return reported > 0 ? reported : zpl ? 203 : 0;
    }

    /// <summary>The protocol state for PRINTER_INFO_2's Status and Attributes and its job count.</summary>
    public static PrinterState StateOf(uint status, uint attributes, uint jobs, out string message)
    {
        message = "";
        if ((status & 0x1) != 0) return PrinterState.Paused;
        if ((attributes & 0x400) != 0 || (status & (0x80 | 0x1000 | 0x800000 | 0x2000000)) != 0) return PrinterState.Offline;
        foreach (var (bit, text) in ErrorBits)
        {
            if ((status & bit) != 0)
            {
                message = text;
                return PrinterState.Error;
            }
        }
        if ((status & (0x200 | 0x400 | 0x4000)) != 0 || jobs > 0) return PrinterState.Busy;
        return PrinterState.Ready;
    }

    /// <summary>Label printers first, then the rest, each group by name.</summary>
    public static IReadOnlyList<Printer> Sort(IEnumerable<Printer> printers) =>
        [.. printers.OrderBy(p => p.Kind == PrinterKind.Thermal ? 0 : 1).ThenBy(p => p.Name, StringComparer.OrdinalIgnoreCase)];

    private static readonly (uint Bit, string Text)[] ErrorBits =
    [
        (0x8, "Paper jam"),
        (0x10, "Out of paper"),
        (0x40, "Paper problem"),
        (0x20, "Waiting for manual feed"),
        (0x400000, "Door open"),
        (0x40000, "Out of toner"),
        (0x800, "Output bin full"),
        (0x200000, "Out of memory"),
        (0x80000, "Page too complex"),
        (0x100000, "Needs attention"),
        (0x2, "Error"),
    ];

    [GeneratedRegex(@"^\d{1,3}(\.\d{1,3}){3}")]
    private static partial Regex IPv4Prefix();

    private static bool Matches((int Width, int Length) size, int width, int length)
    {
        int w = Math.Min(size.Width, size.Length), l = Math.Max(size.Width, size.Length);
        return Math.Abs(w - width) <= PaperTolerance && Math.Abs(l - length) <= PaperTolerance;
    }
}
