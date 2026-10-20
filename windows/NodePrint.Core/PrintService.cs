namespace NodePrint.Core;

public interface IPrintBackend
{
    /// <summary>All printers the app may use, hidden virtual queues already left out, in any order.</summary>
    IReadOnlyList<Printer> GetPrinters();

    /// <summary>The printer with this id with its current state, or null when it is not installed or hidden.</summary>
    Printer? FindPrinter(string id);

    /// <summary>Opens the PDF, PNG or JPEG, hands the whole job to the OS spooler and returns the page count; throws
    /// <see cref="ApiError"/> for BAD_DOCUMENT and PRINT_FAILED.</summary>
    Task<int> PrintAsync(Printer printer, Channel channel, ReadOnlyMemory<byte> document, int copies, string title);
}

public sealed class PrintService
{
    private readonly IPrintBackend backend;
    private readonly ConfigStore store;
    private readonly Lock gate = new();
    private readonly SerialQueue labelQueue = new();
    private readonly SerialQueue documentQueue = new();
    private AppConfig config;
    private long lastLinkedTicks;

    public PrintService(IPrintBackend backend, ConfigStore store, AppConfig config)
    {
        this.backend = backend;
        this.store = store;
        this.config = config;
    }

    /// <summary>Loads the config file, or on first run picks the printers and writes it. A file that does not parse is
    /// left alone (it is someone's hand edit) and the app starts with nothing chosen.</summary>
    public static PrintService Open(IPrintBackend backend, ConfigStore store)
    {
        AppConfig? config;
        try
        {
            config = store.Load();
        }
        catch (System.Text.Json.JsonException)
        {
            return new PrintService(backend, store, new AppConfig());
        }
        if (config is null)
        {
            config = new AppConfig { Channels = FirstRunChoice(backend.GetPrinters()) };
            store.Save(config);
        }
        return new PrintService(backend, store, config);
    }

    public static ChannelChoices FirstRunChoice(IReadOnlyList<Printer> printers) => new()
    {
        Label = PrinterRules.Sort(printers).FirstOrDefault(p => p.Kind == PrinterKind.Thermal)?.Id,
        Document = printers.FirstOrDefault(p => p.Default && p.Kind != PrinterKind.Thermal)?.Id,
    };

    public IReadOnlyList<string> AllowedOrigins
    {
        get { lock (gate) return config.AllowedOrigins; }
    }

    public bool LaunchAtLogin
    {
        get { lock (gate) return config.LaunchAtLogin; }
        set => Update(c => c.LaunchAtLogin = value);
    }

    /// <summary>When an allowed NODE origin last got a successful answer, or null when none has yet.</summary>
    public DateTimeOffset? LastLinked
    {
        get
        {
            long ticks = Interlocked.Read(ref lastLinkedTicks);
            return ticks == 0 ? null : new DateTimeOffset(ticks, TimeSpan.Zero);
        }
    }

    public void MarkLinked() => Interlocked.Exchange(ref lastLinkedTicks, DateTimeOffset.UtcNow.UtcTicks);

    public string? ChosenId(Channel channel)
    {
        lock (gate) return channel == Channel.Label ? config.Channels.Label : config.Channels.Document;
    }

    public void Choose(Channel channel, string printerId) => Update(c =>
    {
        if (channel == Channel.Label) c.Channels.Label = printerId;
        else c.Channels.Document = printerId;
    });

    public IReadOnlyList<Printer> Printers() => PrinterRules.Sort(backend.GetPrinters());

    public ChannelStatus ChannelStatus(Channel channel)
    {
        string? id = ChosenId(channel);
        if (id is null) return new ChannelStatus(null, ChannelState.None);
        var printer = backend.FindPrinter(id);
        return printer is null
            ? new ChannelStatus(Printer.Missing(id), ChannelState.Missing)
            : new ChannelStatus(printer, ToChannelState(printer.State));
    }

    public StatusResponse Status() => new(AppInfo.Id, AppInfo.Version, AppInfo.Platform,
        new ChannelsStatus(ChannelStatus(Channel.Label), ChannelStatus(Channel.Document)));

    /// <summary>Queues a job whose body has been received in full: it prints on the printer chosen now, after the
    /// jobs already queued on its channel.</summary>
    public async Task<JobInfo> PrintAsync(Channel channel, int copies, string? title, ReadOnlyMemory<byte> document)
    {
        string id = ChosenId(channel) ?? throw ApiError.NoPrinter(channel);
        var printer = backend.FindPrinter(id) ?? throw ApiError.PrinterUnavailable(id, ChannelState.Missing);
        if (printer.State is PrinterState.Offline or PrinterState.Error or PrinterState.Paused)
        {
            throw ApiError.PrinterUnavailable(printer.Name, ToChannelState(printer.State), printer.StateMessage);
        }

        using var turn = (channel == Channel.Label ? labelQueue : documentQueue).Enter();
        await turn.Ready;
        string jobTitle = string.IsNullOrWhiteSpace(title)
            ? channel == Channel.Label ? "NODE label" : "NODE document"
            : title;
        int pages = await backend.PrintAsync(printer, channel, document, copies, jobTitle);
        return new JobInfo(channel, printer.Name, pages, copies);
    }

    private static ChannelState ToChannelState(PrinterState state) => state switch
    {
        PrinterState.Busy => ChannelState.Busy,
        PrinterState.Paused => ChannelState.Paused,
        PrinterState.Offline => ChannelState.Offline,
        PrinterState.Error => ChannelState.Error,
        _ => ChannelState.Ready,
    };

    private void Update(Action<AppConfig> change)
    {
        lock (gate)
        {
            var next = config.Clone();
            change(next);
            store.Save(next);
            config = next;
        }
    }
}

/// <summary>Lets work run one item at a time in the order <see cref="Enter"/> was called.</summary>
internal sealed class SerialQueue
{
    private readonly Lock gate = new();
    private Task tail = Task.CompletedTask;

    public Turn Enter()
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Task previous;
        lock (gate)
        {
            previous = tail;
            tail = done.Task;
        }
        return new Turn(previous, done);
    }

    public sealed class Turn(Task previous, TaskCompletionSource done) : IDisposable
    {
        public Task Ready => previous;

        // A turn given up early still lets the next one start only after the one before it has finished.
        public void Dispose() => previous.ContinueWith(_ => done.TrySetResult(), TaskScheduler.Default);
    }
}
