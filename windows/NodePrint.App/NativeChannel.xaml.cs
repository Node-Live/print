using Microsoft.UI.Xaml.Controls;
using NodePrint.Core;

namespace NodePrint.App;

/// <summary>One channel in the plain WinUI window: a combo box of printers, a line of facts and an info bar when the
/// printer needs attention.</summary>
public sealed partial class NativeChannel : UserControl
{
    private Channel channel;
    private PrintService? service;
    private bool updating;

    public NativeChannel()
    {
        InitializeComponent();
    }

    public void Setup(Channel channel, PrintService service)
    {
        this.channel = channel;
        this.service = service;
        bool label = channel == Channel.Label;
        TitleText.Text = Strings.Get(label ? "LabelPrinter" : "DocumentPrinter");
        DetailText.Text = Strings.Get(label ? "LabelPrinterDetail" : "DocumentPrinterDetail");
        Printers.PlaceholderText = Strings.Get("ChoosePrinter");
    }

    public void Show(IReadOnlyList<Printer> printers, ChannelStatus status)
    {
        string? chosen = service?.ChosenId(channel);
        var names = printers.Select(p => p.Id).ToList();
        if (status.State == ChannelState.Missing && chosen is not null) names.Add(chosen);

        updating = true;
        if (!names.SequenceEqual(Printers.Items.Cast<ComboBoxItem>().Select(i => (string)i.Tag)))
        {
            Printers.Items.Clear();
            foreach (string id in names) Printers.Items.Add(new ComboBoxItem { Content = id, Tag = id });
        }
        Printers.SelectedItem = Printers.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == chosen);
        updating = false;

        var parts = new List<string>();
        if (status.Printer is { } printer && status.State != ChannelState.Missing)
        {
            if (printer.Kind == PrinterKind.Thermal) parts.Add(Strings.Get("Thermal"));
            var papers = PrinterRules.CardPapers(printer, channel);
            if (papers.Count > 0) parts.Add(string.Join(" / ", papers.Select(PaperName)));
            if (Look.ConnectionKey(printer.Connection) is { } connection) parts.Add(Strings.Get(connection));
        }
        parts.Add(Strings.Get(Look.Of(status.State).Key));
        InfoText.Text = string.Join(" · ", parts);

        StateBar.Severity = status.State switch
        {
            ChannelState.Paused => InfoBarSeverity.Warning,
            ChannelState.None => InfoBarSeverity.Informational,
            _ => InfoBarSeverity.Error,
        };
        StateBar.Title = Strings.Get(Look.Of(status.State).Key);
        StateBar.Message = status.Printer?.StateMessage ?? "";
        StateBar.IsOpen = status.State is not (ChannelState.Ready or ChannelState.Busy);
    }

    private static string PaperName(string paper) => paper switch
    {
        Papers.FourBySix => Strings.Get("Paper4x6"),
        Papers.Letter => Strings.Get("PaperLetter"),
        _ => paper,
    };

    private void OnSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (updating || service is null || Printers.SelectedItem is not ComboBoxItem { Tag: string id }) return;
        if (id != service.ChosenId(channel)) service.Choose(channel, id);
    }
}
