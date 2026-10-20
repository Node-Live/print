namespace NodePrint.Core.Tests;

public sealed class PrinterRulesTests
{
    [Theory]
    [InlineData("ZDesigner GX420d", true)]
    [InlineData("ZDesigner ZT410-300dpi ZPL", true)]
    [InlineData("ZDesigner GX420d (EPL)", false)]
    [InlineData("Zebra ZPL II Generic", true)]
    [InlineData("Rollo Printer", false)]
    [InlineData("Brother HL-L2350DW series", false)]
    public void Zpl_queues_are_known_by_driver_name(string driver, bool zpl)
    {
        Assert.Equal(zpl, PrinterRules.IsZpl(driver));
    }

    [Theory]
    [InlineData("PORTPROMPT:", "Microsoft Print To PDF", true)]
    [InlineData("PORTPROMPT:", "Microsoft XPS Document Writer v4", true)]
    [InlineData("nul:", "Send to Microsoft OneNote 16 Driver", true)]
    [InlineData("SHRFAX:", "Microsoft Shared Fax Driver", true)]
    [InlineData("FILE:", "Generic / Text Only", true)]
    [InlineData("Microsoft.Office.OneNote_16001.14326.0_x64__8wekyb3d8bbwe_microsoft.onenoteim_S-1-5-21",
        "Microsoft Software Printer Driver", true)]
    [InlineData(@"C:\ci\label.pdf", "Microsoft Print To PDF", false)]
    [InlineData("USB001", "ZDesigner GX420d", false)]
    public void Virtual_queues_are_hidden(string port, string driver, bool hidden)
    {
        Assert.Equal(hidden, PrinterRules.IsHidden(port, driver));
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
    public void A_queue_is_thermal_when_zpl_or_its_largest_paper_is_label_wide()
    {
        Assert.Equal(PrinterKind.Thermal, PrinterRules.KindOf(true, []));
        Assert.Equal(PrinterKind.Thermal, PrinterRules.KindOf(false, [(1016, 1524), (1016, 2794), (508, 254)]));
        Assert.Equal(PrinterKind.Other, PrinterRules.KindOf(false, [(1016, 1524), (2159, 2794)]));
        Assert.Equal(PrinterKind.Other, PrinterRules.KindOf(false, []));
    }

    [Fact]
    public void A_zpl_queue_that_reports_no_resolution_is_203_dpi()
    {
        Assert.Equal(300, PrinterRules.DpiOf(true, [300]));
        Assert.Equal(203, PrinterRules.DpiOf(true, []));
        Assert.Equal(600, PrinterRules.DpiOf(false, [300, 600]));
        Assert.Equal(0, PrinterRules.DpiOf(false, []));
    }

    [Theory]
    [InlineData(0u, 0u, 0u, PrinterState.Ready, "")]
    [InlineData(0x400u, 0u, 1u, PrinterState.Busy, "")]
    [InlineData(0u, 0u, 2u, PrinterState.Busy, "")]
    [InlineData(0x1u | 0x10u, 0u, 0u, PrinterState.Paused, "")]
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
