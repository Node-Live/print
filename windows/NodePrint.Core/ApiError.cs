namespace NodePrint.Core;

public sealed class ApiError(int status, string code, string message) : Exception(message)
{
    public int Status { get; } = status;
    public string Code { get; } = code;

    public static ApiError ForbiddenOrigin(string origin) =>
        new(403, "FORBIDDEN_ORIGIN", $"The origin {origin} may not use NODE Print.");

    public static ApiError BadChannel() =>
        new(400, "BAD_CHANNEL", "The channel must be \"label\" or \"document\".");

    public static ApiError BadCopies() =>
        new(400, "BAD_COPIES", "Copies must be a whole number from 1 to 99.");

    public static ApiError BadDocument(string detail) =>
        new(400, "BAD_DOCUMENT", $"The body is not a PDF, PNG or JPEG that can be printed: {detail}");

    public static ApiError TooLarge() =>
        new(413, "TOO_LARGE", $"The document is larger than {LocalApi.MaxBodyBytes:N0} bytes.");

    public static ApiError NoPrinter(Channel channel) =>
        new(409, "NO_PRINTER", $"No {ChannelName(channel)} printer is chosen in NODE Print.");

    public static ApiError PrinterUnavailable(string printer, ChannelState state, string detail = "") =>
        new(409, "PRINTER_UNAVAILABLE", state switch
        {
            ChannelState.Missing => $"The printer \"{printer}\" is no longer installed.",
            ChannelState.Paused => $"The printer \"{printer}\" is paused.",
            ChannelState.Error => detail.Length > 0
                ? $"The printer \"{printer}\" reports an error: {detail}."
                : $"The printer \"{printer}\" reports an error.",
            _ => $"The printer \"{printer}\" is offline.",
        });

    public static ApiError PrintFailed(string printer, string detail) =>
        new(500, "PRINT_FAILED", $"The printer \"{printer}\" refused the job: {detail}");

    public static ApiError NotFound() => new(404, "NOT_FOUND", "Not found.");

    public static ApiError MethodNotAllowed() => new(405, "METHOD_NOT_ALLOWED", "Method not allowed.");

    private static string ChannelName(Channel channel) => channel == Channel.Label ? "label" : "document";
}
