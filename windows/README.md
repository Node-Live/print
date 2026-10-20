# NODE Print for Windows

WinUI 3 on the Windows App SDK (unpackaged, self-contained, x64), C# on .NET 10, published with NativeAOT and packaged
with Velopack.

| project                     | what                                                                               |
|-----------------------------|------------------------------------------------------------------------------------|
| `NodePrint.Core`            | protocol models, the local HTTP server, CORS, ZPL encoding, page layout, config    |
| `NodePrint.Printing`        | Windows printing: winspool queues, PDF rendering (`Windows.Data.Pdf`), ZPL and GDI |
| `NodePrint.App`             | the window, the tray icon, single instance, launch at login                        |
| `NodePrint.Core.Tests`      | runs anywhere (`dotnet test windows/NodePrint.Core.Tests`)                         |
| `NodePrint.Printing.Tests`  | Windows only: page vectors through the real renderer, jobs on file-port queues     |

`Core` and `Printing` build on any OS (`EnableWindowsTargeting`); the app's XAML only builds on Windows.

The version is `Version` in `Directory.Build.props`; the window, `GET /status` and the installer all show it.

Config lives in `%LOCALAPPDATA%\NODE Print\config.json` (see `docs/protocol.md`); it is read at start, so restart the
app after editing it by hand.

CI (`.github/workflows/windows.yml`) builds, tests, publishes, packs `Setup.exe` and the portable zip, then points two
"Microsoft Print to PDF" queues at file ports, runs the app against them, takes screenshots and checks the pages that
come out.
