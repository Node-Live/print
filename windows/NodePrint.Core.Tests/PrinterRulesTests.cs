namespace NodePrint.Core.Tests;

public sealed class PrinterRulesTests
{
    [Theory]
    [InlineData("PORTPROMPT:", true)]
    [InlineData("nul:", true)]
    [InlineData("SHRFAX:", true)]
    [InlineData("FILE:", true)]
    [InlineData(@"C:\ci\label.pdf", false)]
    [InlineData("USB001", false)]
    [InlineData("Microsoft.Office.OneNote_16001.14326.0_x64__8wekyb3d8bbwe_microsoft.onenoteim_S-1-5-21", false)]
    public void Queues_are_hidden_by_their_port_only(string port, bool hidden)
    {
        Assert.Equal(hidden, PrinterRules.IsHidden(port));
    }

    [Theory]
    [InlineData("USB001", "USB Monitor", false, Connection.Usb)]
    [InlineData("WSD-6f1b2c3d-0000-0000-0000-000000000000", "WSD Port", false, Connection.Network)]
    [InlineData("IP_192.168.1.20", "Standard TCP/IP Port", false, Connection.Network)]
    [InlineData("192.168.1.20_1", "Standard TCP/IP Port", false, Connection.Network)]
    [InlineData("BRN3C2AF41B9E12", "Standard TCP/IP Port", false, Connection.Network)]
    [InlineData("http://printserver:631/printers/zebra", "", false, Connection.Network)]
    [InlineData("USB001", "USB Monitor", true, Connection.Network)]
    [InlineData("BTHLE001", "", false, Connection.Bluetooth)]
    [InlineData("LPT1:", "Local Port", false, Connection.Other)]
    [InlineData(@"C:\ci\label.pdf", "Local Port", false, Connection.Other)]
    public void The_connection_comes_from_the_port(string port, string monitor, bool shared, Connection connection)
    {
        Assert.Equal(connection, PrinterRules.ConnectionOf(port, monitor, shared));
    }

    [Fact]
    public void Papers_are_the_protocol_sizes_the_driver_lists()
    {
        (int, int)[] sizes = [(2159, 2794), (2100, 2970), (2159, 3556), (1020, 1520), (1048, 2413)];

        Assert.Equal(["4x6", "Letter", "A4"], PrinterRules.PapersOf(sizes));
        Assert.Empty(PrinterRules.PapersOf([(2970, 4200)]));
    }

    [Fact]
    public void A_label_printer_lists_a_label_sized_paper_and_no_letter_or_a4()
    {
        Assert.Equal(PrinterKind.Thermal, PrinterRules.KindOf([(1016, 1524), (508, 254)]));
        Assert.Equal(PrinterKind.Thermal, PrinterRules.KindOf([(1016, 1524), (2032, 2794)]));
        Assert.Equal(PrinterKind.Thermal, PrinterRules.KindOf([(1080, 1500)]));
        Assert.Equal(PrinterKind.Other, PrinterRules.KindOf([(1016, 1524), (2159, 2794)]));
        Assert.Equal(PrinterKind.Other, PrinterRules.KindOf([(1016, 1524), (2100, 2970)]));
        Assert.Equal(PrinterKind.Other, PrinterRules.KindOf([(1100, 1500)]));
        Assert.Equal(PrinterKind.Other, PrinterRules.KindOf([]));
    }

    [Theory]
    [InlineData(0u, 0u, 0u, PrinterState.Ready, "")]
    [InlineData(0x400u, 0u, 1u, PrinterState.Busy, "")]
    [InlineData(0u, 0u, 2u, PrinterState.Busy, "")]
    [InlineData(0x1u, 0u, 3u, PrinterState.Paused, "")]
    [InlineData(0x1u | 0x10u, 0u, 0u, PrinterState.Error, "Out of paper")]
    [InlineData(0x80u | 0x10u | 0x1u, 0u, 0u, PrinterState.Offline, "")]
    [InlineData(0u, 0x400u, 0u, PrinterState.Offline, "")]
    [InlineData(0x80u, 0u, 0u, PrinterState.Offline, "")]
    [InlineData(0x10u, 0u, 0u, PrinterState.Error, "Out of paper")]
    [InlineData(0x2u, 0u, 3u, PrinterState.Error, "Error")]
    [InlineData(0x20000u, 0u, 0u, PrinterState.Ready, "")]
    public void The_state_comes_from_status_attributes_and_jobs(uint status, uint attributes, uint jobs, PrinterState state,
        string message)
    {
        Assert.Equal(state, PrinterRules.StateOf(status, attributes, jobs, out string text));
        Assert.Equal(message, text);
    }

    [Fact]
    public void A_card_names_only_the_papers_its_channel_prints_on()
    {
        var printer = FakeBackend.Make("Brother") with { Papers = ["4x6", "Letter", "A4"] };

        Assert.Equal(["4x6"], PrinterRules.CardPapers(printer, Channel.Label));
        Assert.Equal(["Letter", "A4"], PrinterRules.CardPapers(printer, Channel.Document));
        Assert.Empty(PrinterRules.CardPapers(printer with { Papers = ["Letter"] }, Channel.Label));
    }
}
