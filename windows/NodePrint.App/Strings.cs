using Microsoft.Windows.ApplicationModel.Resources;

namespace NodePrint.App;

/// <summary>Text in the user's Windows display language, English when it is not one we translate.</summary>
internal static class Strings
{
    private static readonly ResourceLoader Loader = new();

    public static string Get(string key) => Loader.GetString(key);
}
