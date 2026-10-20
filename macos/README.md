# NODE Print for macOS

A menu bar app (SwiftUI, macOS 14+, Liquid Glass on macOS 26) that serves `docs/protocol.md` on `127.0.0.1:19233`.

| path                         | what                                                                   |
|------------------------------|------------------------------------------------------------------------|
| `Sources/NodePrintCore`      | local server, CUPS printer list, ZPL, PDF rendering, printing, config  |
| `Sources/NodePrintApp`       | the app: menu bar item, window, printer picker                         |
| `Tests/NodePrintCoreTests`   | protocol, ZPL vectors (`../testdata/zpl`), layout, config, driver jobs |
| `Resources`                  | String Catalog (en, zh-Hans, es) and the app icon                      |
| `scripts/package.sh`         | builds `dist/NODE Print.app`, the zip and the dmg                      |
| `ci/`                        | print queues, screenshots and the smoke run used by the workflow       |

The version lives in `Sources/NodePrintCore/Version.swift`; the window, `/status` and the package all read it.

## Local work

Command Line Tools are enough for the core and for a look at the window (without Liquid Glass):

```sh
swift test                      # driver-job tests run when a CUPS queue exists
swift run NodePrintApp          # strings stay English outside the app bundle
```

`scripts/package.sh` needs Xcode (universal build); CI runs it on `macos-26`.

## Printing

- Label channel, ZPL queue (`docs/zpl.md`): pages are rendered at the queue's dpi, turned into `^GFA` ZPL and sent
  as a raw CUPS job.
- Anything else goes through PDFKit with the paper set on the job: 4 × 6 in for labels (landscape pages turned
  clockwise), Letter for documents (each page in its own orientation, fitted to the printable area).
