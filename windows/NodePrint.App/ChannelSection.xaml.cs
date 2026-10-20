using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using NodePrint.Core;

namespace NodePrint.App;

/// <summary>One channel: its header with the state, and the card that opens the printer list.</summary>
public sealed partial class ChannelSection : UserControl
{
    private Channel channel;
    private PrintService? service;

    public ChannelSection()
    {
        InitializeComponent();
        Loaded += (_, _) => Shadows.Attach(TileShadow, TileShape, blur: 1.5f, offsetY: 1, opacity: 0.06f);
    }

    /// <summary>Raised after the user picked a printer from the list.</summary>
    public event Action? Chosen;

    public void Setup(Channel channel, PrintService service)
    {
        this.channel = channel;
        this.service = service;
        bool label = channel == Channel.Label;
        TitleText.Text = Strings.Get(label ? "LabelPrinter" : "DocumentPrinter");
        DetailText.Text = Strings.Get(label ? "LabelPrinterDetail" : "DocumentPrinterDetail");
        TileIcon.Glyph = label ? "\uE8EC" : "\uF000";
        NoPrintersText.Text = Strings.Get("NoPrinters");
    }

    public void Show(ChannelStatus status)
    {
        var look = Look.Of(status.State);
        StateText.Text = Strings.Get(look.Key);
        StateText.Foreground = look.Ink;
        StateDot.Fill = look.Dot;
        TileDot.Fill = look.Dot;

        var printer = status.Printer;
        NameText.Text = printer?.Name ?? service?.ChosenId(channel) ?? Strings.Get("ChoosePrinter");
        SubtitleText.Text = printer is null ? "" : Subtitle(printer);
        SubtitleText.Visibility = SubtitleText.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        string? connection = printer is null ? null : Look.ConnectionKey(printer.Connection);
        ConnectionText.Text = connection is null ? "" : Strings.Get(connection);
        ConnectionPill.Visibility = connection is null ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>The kind word, only when it is known, then the papers the driver reports for this channel.</summary>
    private string Subtitle(Printer printer)
    {
        var parts = new List<string>();
        if (printer.Kind == PrinterKind.Thermal) parts.Add(Strings.Get("Thermal"));
        var papers = PrinterRules.CardPapers(printer, channel);
        if (papers.Count > 0) parts.Add(string.Join(" / ", papers.Select(PaperName)));
        return string.Join(" · ", parts);
    }

    private static string PaperName(string paper) => paper switch
    {
        Papers.FourBySix => Strings.Get("Paper4x6"),
        Papers.Letter => Strings.Get("PaperLetter"),
        _ => paper,
    };

    /// <summary>Fills the list first and then opens it: a popup that may leave the window is sized when it opens.</summary>
    private async void OnCardClick(object sender, RoutedEventArgs e)
    {
        if (service is null) return;
        try
        {
            var printers = await Task.Run(service.Printers);
            string? chosen = service.ChosenId(channel);
            PickerList.Children.Clear();
            foreach (var printer in printers)
            {
                var row = new PrinterRow(printer, printer.Id == chosen);
                row.Picked += (_, picked) =>
                {
                    service.Choose(channel, picked.Id);
                    Picker.Hide();
                    Chosen?.Invoke();
                };
                PickerList.Children.Add(row);
            }
            NoPrintersText.Visibility = printers.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            FlyoutBase.ShowAttachedFlyout(Card);
        }
        catch (Exception error)
        {
            ErrorLog.Write(error);
        }
    }
}
