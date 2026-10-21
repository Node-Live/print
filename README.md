# NODE Print

The desktop print client for NODE. It sits in the tray (Windows) or menu bar (macOS), holds one label printer
and one document printer, and prints the PDFs the NODE web app sends it over `http://127.0.0.1:19233`.

| directory   | what                                                        |
|-------------|-------------------------------------------------------------|
| `windows/`  | Windows app: WinUI 3 on the Windows App SDK, C# / .NET      |
| `macos/`    | macOS app: SwiftUI                                          |
| `docs/`     | the shared protocol, the ZPL path, the design               |
| `testdata/` | vectors both apps must pass                                 |
| `assets/`   | the NODE mark                                               |

The two apps share no code, only `docs/protocol.md` (the local HTTP contract the web relies on) and
`docs/zpl.md` (how labels reach Zebra printers). Each app is built and packaged by GitHub Actions; see the
workflow in `.github/workflows/` and each app's own README.

Releases live on GitHub (`v<version>` tags). The asset names carry no version — `NodePrint-win-Setup.exe`,
`NodePrint-win-Portable.zip`, `NODE-Print-macos.dmg`, `NODE-Print-macos.zip` — because the NODE web app links
to `releases/latest/download/<asset>`; renaming one means changing the web as well.
