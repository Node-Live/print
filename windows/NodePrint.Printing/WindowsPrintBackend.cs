using System.Collections.Concurrent;
using NodePrint.Core;

namespace NodePrint.Printing;

public sealed class WindowsPrintBackend : IPrintBackend
{
    private const uint AttributeNetwork = 0x10;

    private readonly ConcurrentDictionary<(string Name, string Driver), Capabilities> capabilities = new();
    private IReadOnlyDictionary<string, string> portMonitors = new Dictionary<string, string>();

    public IReadOnlyList<Printer> GetPrinters()
    {
        portMonitors = Spooler.PortMonitors();
        string defaultName = Spooler.DefaultPrinterName();
        return [.. Spooler.Queues().Where(q => !PrinterRules.IsHidden(q.Port, q.Name)).Select(q => Describe(q, defaultName))];
    }

    public Printer? FindPrinter(string id)
    {
        var queue = Spooler.Find(id);
        if (queue is null || PrinterRules.IsHidden(queue.Port, queue.Name)) return null;
        if (!portMonitors.ContainsKey(queue.Port)) portMonitors = Spooler.PortMonitors();
        return Describe(queue, Spooler.DefaultPrinterName());
    }

    public async Task<int> PrintAsync(Printer printer, Channel channel, ReadOnlyMemory<byte> body, int copies, string title)
    {
        var document = await SourceDocument.OpenAsync(body);
        try
        {
            var queue = Spooler.Find(printer.Id) ?? throw new IOException("The printer is no longer installed.");
            await DriverJob.PrintAsync(printer, CapabilitiesOf(queue), channel, document, copies, title);
        }
        catch (Exception e) when (e is not ApiError)
        {
            throw ApiError.PrintFailed(printer.Name, e.Message);
        }
        return document.PageCount;
    }

    internal Capabilities CapabilitiesOf(Queue queue) =>
        capabilities.GetOrAdd((queue.Name, queue.Driver), _ => Spooler.CapabilitiesOf(queue.Name, queue.Port));

    private Printer Describe(Queue queue, string defaultName)
    {
        var caps = CapabilitiesOf(queue);
        bool shared = (queue.Attributes & AttributeNetwork) != 0 || queue.Name.StartsWith(@"\\", StringComparison.Ordinal);
        var state = PrinterRules.StateOf(queue.Status, queue.Attributes, queue.Jobs, out string message);
        return new Printer(
            queue.Name,
            queue.Name,
            queue.Driver,
            PrinterRules.ConnectionOf(queue.Port, portMonitors.GetValueOrDefault(queue.Port, ""), shared),
            PrinterRules.KindOf(caps.PaperSizes),
            PrinterRules.PapersOf(caps.PaperSizes),
            caps.Dpi,
            state,
            message,
            string.Equals(queue.Name, defaultName, StringComparison.OrdinalIgnoreCase));
    }
}
