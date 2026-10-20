# NODE Print for macOS

A menu bar app (SwiftUI, macOS 14+, Liquid Glass on macOS 26) that serves `docs/protocol.md` on `127.0.0.1:19233`.

| path                         | what                                                                   |
|------------------------------|------------------------------------------------------------------------|
| `Sources/NodePrintCore`      | local server, CUPS printer list, printing, config, parked ZPL encoder  |
| `Sources/NodePrintApp`       | the app: menu bar item, window (design and native styles), picker     |
| `Tests/NodePrintCoreTests`   | protocol, ZPL vectors (`../testdata/zpl`), config, driver jobs         |
| `Resources`                  | String Catalog (en, zh-Hans, es) and the app icon                      |
| `scripts/package.sh`         | builds `dist/NODE Print.app`, the zip and the dmg                      |
| `ci/`                        | print queues, screenshots and the smoke run used by the workflow       |

The version lives in `Sources/NodePrintCore/Version.swift`; the window, `/status` and the package all read it.

## Local work

Command Line Tools are enough for the core and for a look at the window. The Liquid Glass code is compiled only
by Swift 6.2+ (`#if compiler(>=6.2)`, the macOS 26 SDK) and picked at run time with `#available(macOS 26, *)`, so
an older toolchain builds the material fallback:

```sh
swift test                      # driver-job tests run when a CUPS queue exists
swift run NodePrintApp          # strings stay English outside the app bundle
```

`scripts/package.sh` needs Xcode (universal build); CI runs it on `macos-26`. Window screenshots (both styles, three
languages) are taken when the workflow is run by hand or the commit message contains `[screenshots]`.

## Printing

Every printer goes through its driver. The body (PDF, or a PNG / JPEG as one page) is opened with PDFKit; copies
are expanded (labels A A B B, documents A B A B) and the job is one AppKit print operation with the channel's
paper set on it: 4 × 6 in for labels (read back, refused when the driver settles on anything else), Letter for
documents. Each page is cut to its crop box, turned by its own rotation, turned again when it does not stand the
way it prints (landscape labels clockwise, landscape documents counter-clockwise), then fitted to the printable
area and centred. ZPL (`docs/zpl.md`) is parked; its encoder only keeps the shared vectors in `testdata/zpl` passing.

## Window styles

`--style design` (default) is the design in `docs/design/`; `--style native` is the same window in SwiftUI's own
controls and styles, for comparison.
