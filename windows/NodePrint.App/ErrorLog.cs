namespace NodePrint.App;

/// <summary>Unexpected failures, appended to error.log next to the config, since a tray app has nowhere to show them.</summary>
internal static class ErrorLog
{
    private static readonly string FilePath = Path.Combine(Path.GetDirectoryName(Core.ConfigStore.DefaultPath)!, "error.log");

    public static void Write(object? error)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.AppendAllText(FilePath, $"{DateTime.Now:O} {error}{Environment.NewLine}");
        }
        catch (IOException)
        {
        }
    }
}
