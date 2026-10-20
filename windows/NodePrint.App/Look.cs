using Microsoft.UI;
using Microsoft.UI.Xaml.Media;
using NodePrint.Core;
using Windows.UI;

namespace NodePrint.App;

/// <summary>The word and the two colours (text, dot) a state is shown with.</summary>
internal sealed record Look(string Key, Brush Ink, Brush Dot)
{
    private static readonly Brush GreenInk = Solid(0x13, 0x81, 0x4D), GreenDot = Solid(0x1B, 0xA8, 0x65);
    private static readonly Brush AmberInk = Solid(0x9A, 0x67, 0x00), AmberDot = Solid(0xE8, 0xA3, 0x17);
    private static readonly Brush RedInk = Solid(0xC4, 0x31, 0x4B), RedDot = Solid(0xE5, 0x48, 0x4D);
    private static readonly Brush GrayInk = Solid(0x85, 0x85, 0x8D), GrayDot = Solid(0xB4, 0xB4, 0xBB);

    public static Look Of(ChannelState state) => state switch
    {
        ChannelState.Ready => new("StateReady", GreenInk, GreenDot),
        ChannelState.Busy => new("StateBusy", GreenInk, GreenDot),
        ChannelState.Paused => new("StatePaused", AmberInk, AmberDot),
        ChannelState.Offline => new("StateOffline", RedInk, RedDot),
        ChannelState.Error => new("StateError", RedInk, RedDot),
        ChannelState.Missing => new("StateMissing", RedInk, RedDot),
        _ => new("StateNone", GrayInk, GrayDot),
    };

    public static Look Of(PrinterState state) => Of(state switch
    {
        PrinterState.Busy => ChannelState.Busy,
        PrinterState.Paused => ChannelState.Paused,
        PrinterState.Offline => ChannelState.Offline,
        PrinterState.Error => ChannelState.Error,
        _ => ChannelState.Ready,
    });

    private static readonly TimeSpan LinkWindow = TimeSpan.FromSeconds(60);

    /// <summary>Linked while a NODE page has had a successful answer in the last minute.</summary>
    public static Look OfLink(DateTimeOffset? lastLinked) =>
        lastLinked is { } at && DateTimeOffset.UtcNow - at < LinkWindow
            ? new("LinkedToNode", GreenInk, GreenDot)
            : new("WaitingForNode", GrayInk, GrayDot);

    public static string? ConnectionKey(Connection connection) => connection switch
    {
        Connection.Usb => "ConnectionUsb",
        Connection.Network => "ConnectionNetwork",
        Connection.Bluetooth => "ConnectionBluetooth",
        _ => null,
    };

    private static SolidColorBrush Solid(byte r, byte g, byte b) => new(Color.FromArgb(255, r, g, b));
}
