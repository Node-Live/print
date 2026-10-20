using NodePrint.Core;

namespace NodePrint.Printing.Tests;

/// <summary>Queue enumeration against the CI machine's own queues. Skipped where the CI queues are not set up.</summary>
public sealed class BackendTests
{
    private readonly WindowsPrintBackend backend = new();

    [Fact]
    public void Lists_the_file_port_queues_and_hides_the_dialog_ones()
    {
        var printers = backend.GetPrinters();
        Assert.SkipUnless(printers.Any(p => p.Id == "NODE CI Label"), "the CI queues are not installed");

        var label = Assert.Single(printers, p => p.Id == "NODE CI Label");
        Assert.Equal(("Microsoft Print To PDF", PrinterLanguage.Driver, Connection.Other), (label.Model, label.Language, label.Connection));
        Assert.Contains(Papers.Letter, label.Papers);
        Assert.DoesNotContain(printers, p => p.Id == "Microsoft Print to PDF");
        File.AppendAllText(Path.Combine(AppContext.BaseDirectory, "driver-jobs.txt"),
            string.Join("\n", printers.Select(p => $"queue {p.Id}: {p.Connection} {p.Kind} [{string.Join(", ", p.Papers)}] {p.Dpi} dpi {p.State}")) + "\n");
    }

    [Fact]
    public void Finds_a_queue_by_name()
    {
        Assert.SkipWhen(Spooler.Find("NODE CI Document") is null, "the CI queues are not installed");

        var printer = backend.FindPrinter("NODE CI Document");

        Assert.Equal("Microsoft Print To PDF", printer?.Model);
        Assert.Null(backend.FindPrinter("No Such Printer"));
    }
}
