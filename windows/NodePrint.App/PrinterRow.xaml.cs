using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using NodePrint.Core;

namespace NodePrint.App;

/// <summary>One printer in a card's list: name, connection and state, a tick on the chosen one.</summary>
public sealed partial class PrinterRow : UserControl
{
    public PrinterRow(Printer printer, bool chosen)
    {
        InitializeComponent();
        Printer = printer;
        Check.Visibility = chosen ? Visibility.Visible : Visibility.Collapsed;
        NameText.Text = printer.Name;
        ConnectionText.Text = Look.ConnectionKey(printer.Connection) is { } key ? Strings.Get(key) : "";
        var look = Look.Of(printer.State);
        StateDot.Fill = look.Dot;
        StateText.Text = Strings.Get(look.Key);
        StateText.Foreground = look.Ink;
        RowButton.Click += (_, _) => Picked?.Invoke(this, printer);
    }

    public Printer Printer { get; }

    public event EventHandler<Printer>? Picked;
}
