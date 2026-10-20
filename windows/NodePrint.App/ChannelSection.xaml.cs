using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
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
        Loaded += (_, _) => Shadows.Attach(TileShadow, TileShape, blur: 3, offsetY: 1, opacity: 0.05f);
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
        PickerList.Children.Clear();
        try
        {
            var printers = await Task.Run(service.Printers);
            string? chosen = service.ChosenId(channel);
            if (printers.Count == 0)
            {
                PickerList.Children.Add(new TextBlock
                {
                    Text = Strings.Get("NoPrinters"),
                    Margin = new Thickness(10, 8, 10, 8),
                    FontSize = 13,
                    Foreground = (Brush)Application.Current.Resources["SecondaryInkBrush"],
                });
            }
            foreach (var printer in printers)
            {
                PickerList.Children.Add(Row(printer, printer.Id == chosen));
            }
            FlyoutBase.ShowAttachedFlyout(Card);
        }
        catch (Exception error)
        {
            ErrorLog.Write(error);
        }
    }

    private Button Row(Printer printer, bool chosen)
    {
        var resources = Application.Current.Resources;
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        if (chosen)
        {
            grid.Children.Add(new FontIcon
            {
                Glyph = "\uE73E",
                FontFamily = TileIcon.FontFamily,
                FontSize = 12,
                Foreground = (Brush)resources["InkBrush"],
            });
        }

        var name = new TextBlock
        {
            Text = printer.Name,
            FontSize = 13,
            FontWeight = FontWeights.Medium,
            Foreground = (Brush)resources["InkBrush"],
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(name, 1);
        grid.Children.Add(name);

        if (Look.ConnectionKey(printer.Connection) is { } connectionKey)
        {
            var connection = new TextBlock
            {
                Text = Strings.Get(connectionKey),
                FontSize = 12,
                Foreground = (Brush)resources["SecondaryInkBrush"],
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(connection, 2);
            grid.Children.Add(connection);
        }

        var look = Look.Of(printer.State);
        var state = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        state.Children.Add(new Ellipse { Width = 6, Height = 6, Fill = look.Dot, VerticalAlignment = VerticalAlignment.Center });
        state.Children.Add(new TextBlock { Text = Strings.Get(look.Key), FontSize = 12, Foreground = look.Ink });
        Grid.SetColumn(state, 3);
        grid.Children.Add(state);

        var row = new Button { Style = (Style)resources["PrinterRowStyle"], Content = grid };
        row.Click += (_, _) =>
        {
            service?.Choose(channel, printer.Id);
            Picker.Hide();
            Chosen?.Invoke();
        };
        return row;
    }
}
