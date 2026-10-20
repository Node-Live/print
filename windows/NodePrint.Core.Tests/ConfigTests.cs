namespace NodePrint.Core.Tests;

public sealed class ConfigTests : IDisposable
{
    private readonly DirectoryInfo directory = Directory.CreateTempSubdirectory("nodeprint-");

    private ConfigStore Store => new(Path.Combine(directory.FullName, "NODE Print", "config.json"));

    public void Dispose() => directory.Delete(true);

    [Fact]
    public void No_file_means_first_run()
    {
        Assert.Null(Store.Load());
    }

    [Fact]
    public void Saves_and_loads_the_protocol_shape()
    {
        var config = new AppConfig
        {
            Channels = new ChannelChoices { Label = "ZDesigner GX420d", Document = "Brother HL-L2350DW series" },
            AllowedOrigins = ["https://staging.example.com"],
            LaunchAtLogin = false,
        };

        Store.Save(config);
        var loaded = Store.Load()!;

        Assert.Equal(("ZDesigner GX420d", "Brother HL-L2350DW series"), (loaded.Channels.Label, loaded.Channels.Document));
        Assert.Equal(["https://staging.example.com"], loaded.AllowedOrigins);
        Assert.False(loaded.LaunchAtLogin);
        string json = File.ReadAllText(Store.Path);
        Assert.Contains("\"channels\"", json, StringComparison.Ordinal);
        Assert.Contains("\"allowedOrigins\"", json, StringComparison.Ordinal);
        Assert.Contains("\"launchAtLogin\": false", json, StringComparison.Ordinal);
    }

    [Fact]
    public void Reads_a_hand_edited_file()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Store.Path)!);
        File.WriteAllText(Store.Path, """
            {
              // the warehouse's own staging site
              "allowedOrigins": ["https://staging.example.com",],
            }
            """);

        var loaded = Store.Load()!;

        Assert.Equal(["https://staging.example.com"], loaded.AllowedOrigins);
        Assert.Null(loaded.Channels.Label);
        Assert.True(loaded.LaunchAtLogin);
    }

    [Fact]
    public void First_run_picks_the_first_thermal_printer_and_the_default_printer()
    {
        Printer[] printers =
        [
            FakeBackend.Make("Brother", isDefault: true),
            FakeBackend.Make("Zebra", PrinterKind.Thermal),
            FakeBackend.Make("Rollo", PrinterKind.Thermal),
        ];

        var choice = PrintService.FirstRunChoice(printers);

        Assert.Equal(("Rollo", "Brother"), (choice.Label, choice.Document));
    }

    [Fact]
    public void First_run_leaves_documents_unset_when_the_default_printer_is_thermal()
    {
        var choice = PrintService.FirstRunChoice([FakeBackend.Make("Zebra", PrinterKind.Thermal, isDefault: true), FakeBackend.Make("Brother")]);

        Assert.Equal(("Zebra", null), (choice.Label, choice.Document));
    }

    [Fact]
    public void Opening_without_a_config_writes_the_first_run_choice()
    {
        var backend = new FakeBackend();
        backend.Installed.Add(FakeBackend.Make("Zebra", PrinterKind.Thermal));

        var service = PrintService.Open(backend, Store);

        Assert.Equal("Zebra", service.ChosenId(Channel.Label));
        Assert.Equal("Zebra", Store.Load()!.Channels.Label);
    }

    [Fact]
    public void A_first_run_that_cannot_see_the_printers_writes_nothing()
    {
        var backend = new FakeBackend { Failure = new IOException("EnumPrinters: The RPC server is unavailable.") };

        var service = PrintService.Open(backend, Store);

        Assert.Null(service.ChosenId(Channel.Label));
        Assert.Null(Store.Load());
    }

    [Fact]
    public void Opening_with_a_config_keeps_the_user_choice()
    {
        Store.Save(new AppConfig());
        var backend = new FakeBackend();
        backend.Installed.Add(FakeBackend.Make("Zebra", PrinterKind.Thermal));

        var service = PrintService.Open(backend, Store);

        Assert.Null(service.ChosenId(Channel.Label));
    }

    [Fact]
    public void A_config_that_does_not_parse_is_left_alone()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Store.Path)!);
        File.WriteAllText(Store.Path, "{ \"channels\": ");
        var backend = new FakeBackend();
        backend.Installed.Add(FakeBackend.Make("Zebra", PrinterKind.Thermal));

        var service = PrintService.Open(backend, Store);

        Assert.Null(service.ChosenId(Channel.Label));
        Assert.Equal("{ \"channels\": ", File.ReadAllText(Store.Path));
    }

    [Fact]
    public void Choosing_a_printer_is_saved()
    {
        Store.Save(new AppConfig());
        var service = PrintService.Open(new FakeBackend(), Store);

        service.Choose(Channel.Document, "Brother");
        service.LaunchAtLogin = false;

        var loaded = Store.Load()!;
        Assert.Equal("Brother", loaded.Channels.Document);
        Assert.False(loaded.LaunchAtLogin);
    }
}
