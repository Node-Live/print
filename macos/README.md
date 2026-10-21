# NODE Print for macOS

A menu bar app (SwiftUI, macOS 14+) that serves `docs/protocol.md` on `127.0.0.1:19233`.

| path                       | what                                                                             |
|----------------------------|----------------------------------------------------------------------------------|
| `Sources/NodePrintCore`    | local server, CUPS printer list, printing, config, updates, parked ZPL encoder   |
| `Sources/NodePrintApp`     | the app: menu bar item, window, printer picker                                   |
| `Tests/NodePrintCoreTests` | protocol, ZPL vectors (`../testdata/zpl`), config, driver jobs, updates          |
| `Resources`                | String Catalog (en, zh-Hans, es) and the app icon                                |
| `scripts/package.sh`       | builds `dist/NODE Print.app`, the zip and the dmg                                |
| `ci/`                      | print queues, screenshots, the smoke run and the update run used by the workflow |

The version lives in `Sources/NodePrintCore/Version.swift`; the window, `/status` and the package all read it.

## Local work

Command Line Tools are enough for the core and for a look at the window:

```sh
swift test                      # driver-job tests run when a CUPS queue exists
swift run NodePrintApp          # strings stay English outside the app bundle
```

`scripts/package.sh` needs Xcode (universal build); CI runs it on `macos-26`. Window screenshots (three languages) are taken when the workflow is run by hand or the commit message contains `[screenshots]`.

## Printing

Every printer goes through its driver. The body (PDF, or a PNG / JPEG as one page) is opened with PDFKit; copies
are expanded (labels A A B B, documents A B A B) and the job is one AppKit print operation with the channel's
paper set on it: 4 × 6 in for labels (read back, refused when the driver settles on anything else), Letter for
documents. Each page is cut to its crop box, turned by its own rotation, turned again when it does not stand the
way it prints (landscape labels clockwise, landscape documents counter-clockwise), then fitted to the printable
area and centred. ZPL (`docs/zpl.md`) is parked; its encoder only keeps the shared vectors in `testdata/zpl` passing.

## Updates

The app updates itself from the latest GitHub release while it is idle (`../docs/updates.md`) and logs to
`~/Library/Logs/NODE Print/update.log`. `ci/update.py` proves the chain on the packed app: a copy relabelled 9.9.9 is
served from a local feed (`NODE_PRINT_UPDATES`), and the app installed in a temp folder downloads it, swaps the
bundles and comes back listening from the new one.
