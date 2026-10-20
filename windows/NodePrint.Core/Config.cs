using System.Text.Json;
using System.Text.Json.Serialization;

namespace NodePrint.Core;

public sealed class ChannelChoices
{
    public string? Label { get; set; }
    public string? Document { get; set; }
}

public sealed class AppConfig
{
    public ChannelChoices Channels { get; set; } = new();
    public List<string> AllowedOrigins { get; set; } = [];
    public bool LaunchAtLogin { get; set; } = true;

    public AppConfig Clone() => new()
    {
        Channels = new ChannelChoices { Label = Channels.Label, Document = Channels.Document },
        AllowedOrigins = [.. AllowedOrigins],
        LaunchAtLogin = LaunchAtLogin,
    };
}

public sealed class ConfigStore(string path)
{
    public static string DefaultPath { get; } = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NODE Print", "config.json");

    public string Path { get; } = path;

    /// <summary>The saved config, or null when the file does not exist yet (first run).</summary>
    public AppConfig? Load()
    {
        if (!File.Exists(Path)) return null;
        using var stream = File.OpenRead(Path);
        var config = JsonSerializer.Deserialize(stream, ConfigJson.Default.AppConfig) ?? new AppConfig();
        config.Channels ??= new ChannelChoices();
        config.AllowedOrigins ??= [];
        return config;
    }

    public void Save(AppConfig config)
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
        string temp = Path + ".tmp";
        File.WriteAllBytes(temp, JsonSerializer.SerializeToUtf8Bytes(config, ConfigJson.Default.AppConfig));
        File.Move(temp, Path, overwrite: true);
    }
}

[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    WriteIndented = true,
    ReadCommentHandling = JsonCommentHandling.Skip,
    AllowTrailingCommas = true)]
[JsonSerializable(typeof(AppConfig))]
internal sealed partial class ConfigJson : JsonSerializerContext;
