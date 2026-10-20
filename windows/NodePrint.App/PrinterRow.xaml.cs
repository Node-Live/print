using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using NodePrint.Core;

namespace NodePrint.App;

/// <summary>One printer in a card's list: the name over "connection · ● state", a tick beside the chosen one.</summary>
public sealed partial class PrinterRow : UserControl
{
    public PrinterRow(Printer printer, bool chosen)
    {
        InitializeComponent();
        Check.Visibility = chosen ? Visibility.Visible : Visibility.Collapsed;
        NameText.Text = printer.Name;
        string? connection = Look.ConnectionKey(printer.Connection) is { } key ? Strings.Get(key) : null;
        ConnectionText.Text = connection ?? "";
        ConnectionText.Visibility = Separator.Visibility = connection is null ? Visibility.Collapsed : Visibility.Visible;
        var look = Look.Of(printer.State);
        StateDot.Fill = look.Dot;
        StateText.Text = Strings.Get(look.Key);
        StateText.Foreground = look.Ink;
        RowButton.Click += (_, _) => Picked?.Invoke(this, printer);
    }

    public event EventHandler<Printer>? Picked;
}
