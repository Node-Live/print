namespace NodePrint.Core;

public static class AppInfo
{
    public const string Id = "node-print";
    public const string Platform = "windows";

    /// <summary>Major.minor.patch from the one Version property every project shares.</summary>
    public static string Version { get; } = typeof(AppInfo).Assembly.GetName().Version!.ToString(3);
}
