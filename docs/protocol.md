# NODE Print local protocol (v1)

NODE Print is a small desktop app that sits in the tray / menu bar and prints what the NODE web app sends it:
shipping labels on a label printer, pick sheets and packing slips on a document printer. The Windows and
macOS apps are separate code bases; this document is the one thing they share. The web app talks to both
exactly the same way.

## Transport

- The app listens on `http://127.0.0.1:19233` and nothing else: no `0.0.0.0`, no LAN, no IPv6. The web app
  always uses the literal `127.0.0.1`, never `localhost`.
- One instance per user session. A second launch brings the running window to the front and exits.
- Every response body is JSON (`application/json; charset=utf-8`).
- Errors use the HTTP status plus `{"error": {"code": "…", "message": "…"}}`. `code` is one of the constants
  below; `message` is English, written for a person, and may carry OS detail (printer name, driver error).

### CORS

Only NODE web origins may call the app. The allowed origins are, in this order:

1. `https://nrp.node.live`
2. `http://localhost:5173` and `http://127.0.0.1:5173` (web dev server)
3. Anything listed under `allowedOrigins` in the app's config file

For an allowed `Origin` the app answers with `Access-Control-Allow-Origin: <that origin>`,
`Access-Control-Allow-Methods: GET, POST, OPTIONS`, `Access-Control-Allow-Headers: Content-Type`,
`Access-Control-Allow-Private-Network: true` and `Access-Control-Max-Age: 600`. A preflight (`OPTIONS`)
returns `204`. Any other origin gets no CORS headers at all, so the browser blocks it; requests without an
`Origin` header (curl, tests) are served.

Chrome 142+ asks the user once per site before a public https page may reach `127.0.0.1` (Local Network
Access, "loopback" permission). That is handled on the web side; the app only needs the headers above.

## Resources

### `GET /status`

```json
{
  "app": "node-print",
  "version": "1.0.3",
  "platform": "windows",
  "channels": {
    "label":    { "printer": { …Printer… }, "state": "ready" },
    "document": { "printer": null,          "state": "none" }
  }
}
```

- `platform`: `"windows"` or `"macos"`.
- `channels.<name>.printer`: the chosen printer, or `null` when none is chosen.
- `channels.<name>.state`: `"ready"`, `"busy"` (the queue is printing), `"paused"`, `"offline"`, `"error"`,
  `"missing"` (chosen printer no longer installed) or `"none"` (nothing chosen).

The web calls this with a short timeout (about 1.5 s) to decide whether to offer printing. A failed call means
the app is not running or the browser was not allowed to reach it; the web tells those two apart itself.

### `GET /printers`

```json
{ "printers": [ { …Printer… }, … ] }
```

All printers the OS reports, except virtual ones that need a dialog or write a file (`Microsoft Print to
PDF`, `Microsoft XPS Document Writer`, fax, `FILE:` ports, macOS "Save as PDF" style queues). Order: label
printers first, then the rest, each group by name.

### Printer

```json
{
  "id": "Rollo X1038",
  "name": "Rollo X1038",
  "model": "Rollo Printer",
  "connection": "usb",
  "kind": "thermal",
  "papers": ["4x6"],
  "language": "zpl",
  "dpi": 203,
  "state": "ready",
  "stateMessage": "",
  "default": false
}
```

- `id`: the OS queue name; stable, unique on the machine, used in config and in `channels`.
- `name`: display name (on Windows the printer name; on macOS the queue's printer-info).
- `model`: what the OS knows about make and model (Windows driver name, macOS printer-make-and-model);
  `""` when unknown.
- `connection`: `"usb"`, `"network"`, `"bluetooth"` or `"other"`. Say `"network"` whenever a printer is
  reached over IP; the OS does not tell Wi-Fi from Ethernet, so the app does not claim to.
- `kind`: `"thermal"` for a label printer (ZPL, or a queue whose largest paper is a label size), `"other"`
  otherwise. Nothing else is guessed: no "laser", no "inkjet".
- `papers`: which of `"4x6"`, `"Letter"`, `"A4"` the driver reports. May be empty.
- `language`: `"zpl"` when the queue is a ZPL printer (see `zpl.md`), else `"driver"`.
- `dpi`: the print resolution the driver reports, `203` for a ZPL printer that reports none, `0` otherwise.
- `state`: `"ready"`, `"busy"`, `"paused"`, `"offline"` or `"error"`; `stateMessage` carries the OS text for
  `error`, else `""`.
- `default`: the OS default printer.

### `POST /print?channel=label|document&copies=1&title=…`

Body: the PDF itself, `Content-Type: application/pdf`, at most 50 MB. `copies` defaults to 1 (1–99). `title`
is the job name shown in the OS queue; defaults to `NODE label` / `NODE document`.

- `label`: every page is printed as one 4 × 6 in label, portrait. A landscape page is rotated 90° clockwise
  first. The page is scaled to fit inside the label (aspect kept) and centred. ZPL printers get raw ZPL
  (`zpl.md`); other printers get a 4 × 6 in job through the OS driver with the paper set on the job, not in
  the printer's defaults.
- `document`: every page is printed on Letter, in the page's own orientation, scaled to fit the printable area
  and centred, through the OS driver.

Jobs on one channel are handed to the OS in arrival order, one at a time, so a batch of labels sent one
request after another comes out in order. The response is sent once the job is in the OS queue (or, for ZPL,
written to the printer), not when paper comes out.

```json
{ "job": { "channel": "label", "printer": "ZDesigner GX420d", "pages": 1, "copies": 1 } }
```

Errors:

| status | code                  | when                                                   |
|--------|-----------------------|--------------------------------------------------------|
| 400    | `BAD_CHANNEL`         | `channel` is missing or not `label` / `document`       |
| 400    | `BAD_COPIES`          | `copies` is not 1–99                                   |
| 400    | `BAD_DOCUMENT`        | the body is not a PDF the app can open, or has 0 pages |
| 413    | `TOO_LARGE`           | body over 50 MB                                        |
| 409    | `NO_PRINTER`          | the channel has no printer chosen                      |
| 409    | `PRINTER_UNAVAILABLE` | chosen printer is missing, offline or paused           |
| 500    | `PRINT_FAILED`        | the OS or the printer refused the job (`message` says) |

Anything else is `404 {"error":{"code":"NOT_FOUND"}}` or `405 {"error":{"code":"METHOD_NOT_ALLOWED"}}`.

## Config file

JSON, written by the app, hand-editable:

- Windows: `%LOCALAPPDATA%\NODE Print\config.json`
- macOS: `~/Library/Application Support/NODE Print/config.json`

```json
{
  "channels": { "label": "ZDesigner GX420d", "document": "Brother HL-L2350DW series" },
  "allowedOrigins": [],
  "launchAtLogin": true
}
```

Channel values are printer `id`s. On first run the app picks the first `thermal` printer for `label` and the
OS default printer (if not thermal) for `document`; the user can change both in the window.
