# NODE Print for Windows

WinUI 3 on the Windows App SDK (unpackaged, self-contained, x64), C# on .NET 10, published with NativeAOT and packaged
with Velopack.

| project                     | what                                                                               |
|-----------------------------|------------------------------------------------------------------------------------|
| `NodePrint.Core`            | protocol models, the local HTTP server, CORS, page layout, config                  |
| `NodePrint.Printing`        | Windows printing: winspool queues, PDF and image rendering, GDI jobs               |
| `NodePrint.App`             | the window, the tray icon, single instance, launch at login                        |
| `NodePrint.Core.Tests`      | runs anywhere (`dotnet test windows/NodePrint.Core.Tests`)                         |
| `NodePrint.Printing.Tests`  | Windows only: jobs on file-port queues, checked for page size and orientation      |

`Core` and `Printing` build on any OS (`EnableWindowsTargeting`); the app's XAML only builds on Windows.

The version is `Version` in `Directory.Build.props`; the window, `GET /status` and the installer all show it.

Config lives in `%LOCALAPPDATA%\NODE Print\config.json` (see `docs/protocol.md`); it is read at start, so restart the
app after editing it by hand. Unexpected failures (including the port being taken by another program) are appended to
`error.log` in the same folder.

Every job goes through the printer's driver: each page of the PDF (`Windows.Data.Pdf`) or the PNG / JPEG is rendered
at the printer's resolution for the printable area and drawn through GDI pixel for pixel, on a DEVMODE that is the
driver's own with the paper (4 × 6 in or Letter) and orientation set; a label job stops when the driver did not take
4 × 6 in. Labels go as a 1-bit bitmap: black below half grey, white above, no dithering, images scaled by nearest
neighbour.

`--tray` starts the app in the tray, as the Run key does.

The app updates itself from the GitHub releases through Velopack, hourly and only while no job is printing
(`docs/updates.md`); each download, install and failure is a line in `error.log`. `NODE_PRINT_UPDATES=<feed URL>`
points it at a Velopack feed instead, with the first check 2 s after start.

A print request carries the document itself or, as JSON `{"url": …}`, a URL the app downloads in the channel's queue.

CI (`.github/workflows/windows.yml`) builds, tests, publishes, packs `Setup.exe` and the portable zip, then points two
"Microsoft Print to PDF" queues at file ports, runs the app against them (bytes and URL forms), takes screenshots and
checks the pages that come out. Last, it installs `Setup.exe`, serves a feed with the same build packed again as 9.9.9 and
checks that the installed app updates itself to it through the delta and comes back listening.
