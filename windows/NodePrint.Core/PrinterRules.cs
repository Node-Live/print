using System.Text.RegularExpressions;

namespace NodePrint.Core;

/// <summary>How a Windows print queue, as winspool describes it, maps onto the protocol's printer fields.</summary>
public static partial class PrinterRules
{
    private const int LabelShortEdgeMax = 1080; // 4.25 in (108 mm), in the 0.1 mm units DeviceCapabilities reports
    private const int PaperTolerance = 10;

    private static readonly string[] HiddenPorts = ["PORTPROMPT:", "FILE:", "NUL", "SHRFAX:"];

    /// <summary>Queues whose port opens a dialog or is not a device. By port only, never by name.</summary>
    public static bool IsHidden(string portName) =>
        HiddenPorts.Any(p => portName.StartsWith(p, StringComparison.OrdinalIgnoreCase));

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

    /// <summary>A label printer lists a paper no wider than 4.25 in and neither Letter nor A4; office printers always
    /// list one of those, label drivers none, even when they also list wide sizes for other models.</summary>
    public static PrinterKind KindOf(IReadOnlyCollection<(int Width, int Length)> sizes)
    {
        bool labelSized = sizes.Any(s => Math.Min(s.Width, s.Length) is > 0 and <= LabelShortEdgeMax);
        bool office = sizes.Any(s => Matches(s, 2159, 2794) || Matches(s, 2100, 2970));
        return labelSized && !office ? PrinterKind.Thermal : PrinterKind.Other;
    }

    /// <summary>The papers a channel's card names: the label size for labels, Letter and A4 for documents.</summary>
    public static IReadOnlyList<string> CardPapers(Printer printer, Channel channel) => channel == Channel.Label
        ? [.. printer.Papers.Where(p => p == Papers.FourBySix)]
        : [.. printer.Papers.Where(p => p is Papers.Letter or Papers.A4)];

    /// <summary>The protocol state for PRINTER_INFO_2's Status and Attributes and its job count; when several apply,
    /// offline wins over error, error over paused, paused over busy.</summary>
    public static PrinterState StateOf(uint status, uint attributes, uint jobs, out string message)
    {
        message = "";
        if ((attributes & 0x400) != 0 || (status & (0x80 | 0x1000 | 0x800000 | 0x2000000)) != 0) return PrinterState.Offline;
        foreach (var (bit, text) in ErrorBits)
        {
            if ((status & bit) != 0)
            {
                message = text;
                return PrinterState.Error;
            }
        }
        if ((status & 0x1) != 0) return PrinterState.Paused;
        if ((status & (0x200 | 0x400 | 0x4000)) != 0 || jobs > 0) return PrinterState.Busy;
        return PrinterState.Ready;
    }

    /// <summary>Label printers first, then the rest, each group by name.</summary>
    public static IReadOnlyList<Printer> Sort(IEnumerable<Printer> printers) =>
        [.. printers.OrderBy(p => p.Kind == PrinterKind.Thermal ? 0 : 1).ThenBy(p => p.Name, StringComparer.OrdinalIgnoreCase)];

    /// <summary>Whether a driver paper (0.1 mm) is this size in either orientation, give or take a millimetre.</summary>
    public static bool Matches((int Width, int Length) size, int width, int length)
    {
        int w = Math.Min(size.Width, size.Length), l = Math.Max(size.Width, size.Length);
        return Math.Abs(w - Math.Min(width, length)) <= PaperTolerance && Math.Abs(l - Math.Max(width, length)) <= PaperTolerance;
    }

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
}
