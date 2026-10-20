using System.Text.Json.Serialization;

namespace NodePrint.Core;

public enum Channel
{
    [JsonStringEnumMemberName("label")] Label,
    [JsonStringEnumMemberName("document")] Document,
}

public enum Connection
{
    [JsonStringEnumMemberName("usb")] Usb,
    [JsonStringEnumMemberName("network")] Network,
    [JsonStringEnumMemberName("bluetooth")] Bluetooth,
    [JsonStringEnumMemberName("other")] Other,
}

public enum PrinterKind
{
    [JsonStringEnumMemberName("thermal")] Thermal,
    [JsonStringEnumMemberName("other")] Other,
}

public enum PrinterLanguage
{
    [JsonStringEnumMemberName("zpl")] Zpl,
    [JsonStringEnumMemberName("driver")] Driver,
}

public enum PrinterState
{
    [JsonStringEnumMemberName("ready")] Ready,
    [JsonStringEnumMemberName("busy")] Busy,
    [JsonStringEnumMemberName("paused")] Paused,
    [JsonStringEnumMemberName("offline")] Offline,
    [JsonStringEnumMemberName("error")] Error,
}

public enum ChannelState
{
    [JsonStringEnumMemberName("ready")] Ready,
    [JsonStringEnumMemberName("busy")] Busy,
    [JsonStringEnumMemberName("paused")] Paused,
    [JsonStringEnumMemberName("offline")] Offline,
    [JsonStringEnumMemberName("error")] Error,
    [JsonStringEnumMemberName("missing")] Missing,
    [JsonStringEnumMemberName("none")] None,
}

public static class Papers
{
    public const string FourBySix = "4x6";
    public const string Letter = "Letter";
    public const string A4 = "A4";
}

public sealed record Printer(
    string Id,
    string Name,
    string Model,
    Connection Connection,
    PrinterKind Kind,
    IReadOnlyList<string> Papers,
    PrinterLanguage Language,
    int Dpi,
    PrinterState State,
    string StateMessage,
    bool Default);

public sealed record ChannelStatus(Printer? Printer, ChannelState State);

public sealed record ChannelsStatus(ChannelStatus Label, ChannelStatus Document);

public sealed record StatusResponse(string App, string Version, string Platform, ChannelsStatus Channels);

public sealed record PrintersResponse(IReadOnlyList<Printer> Printers);

public sealed record JobInfo(Channel Channel, string Printer, int Pages, int Copies);

public sealed record JobResponse(JobInfo Job);

public sealed record ErrorDetail(string Code, string Message);

public sealed record ErrorResponse(ErrorDetail Error);

[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    UseStringEnumConverter = true)]
[JsonSerializable(typeof(StatusResponse))]
[JsonSerializable(typeof(PrintersResponse))]
[JsonSerializable(typeof(JobResponse))]
[JsonSerializable(typeof(ErrorResponse))]
public sealed partial class ProtocolJson : JsonSerializerContext;
