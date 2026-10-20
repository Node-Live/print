# NODE Print local protocol (v1)

NODE Print is a small desktop app that sits in the tray / menu bar and prints what the NODE web app sends it:
shipping labels on a label printer, pick sheets and packing slips on a document printer. The Windows and
macOS apps are separate code bases; this document is the one thing they share. The web app talks to both
exactly the same way. Everything prints through the OS printer driver; sending ZPL straight to Zebra printers
(`zpl.md`) is parked, not part of v1.

## Transport

- The app listens on `http://127.0.0.1:19233` and nothing else: no `0.0.0.0`, no LAN, no IPv6. The web app
  always uses the literal `127.0.0.1`, never `localhost`.
- One instance per machine (the port belongs to the machine, not to a user session). A second launch brings
  the running window to the front and exits. When the port cannot be bound (something else holds it) the
  window still opens, shows "Port 19233 is in use" under the header, and the app retries every 5 s; it never
  looks healthy while the server is down.
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
`Access-Control-Allow-Private-Network: true` and `Access-Control-Max-Age: 600`. A preflight (`OPTIONS`, any
path) returns `204`. A request carrying any other `Origin` is answered `403` with code `FORBIDDEN_ORIGIN`, no
CORS headers, and nothing is done (a browser only hides the response from a foreign page; it still sends the
request, and a page must not be able to make a label printer print by posting a "simple" request). Requests
without an `Origin` header (curl, tests) are served.

What the browser side has to live with (the app only needs the headers above):

- Chrome 142+ / Edge ask the user once per site before a public https page may reach `127.0.0.1` (Local
  Network Access, the "loopback" permission since Chrome 145). The old `Access-Control-Allow-Private-Network`
  header does not grant it; the user does, in the prompt.
- Safari does not let an https page call plain-http loopback (WebKit treats it as mixed content). v1 offers
  direct printing in Chrome and Edge; Safari keeps the download buttons.
- The web separates the first connection (no short timeout: the user may be answering the permission prompt)
  from later probes (short timeout). A failed fetch does not say whether the app is not running, the
  permission was refused or the browser blocked the call; the web shows one message for all of them, "Cannot
  reach NODE Print on this computer", with the install and permission hints, and never claims the app is not
  installed.

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

- `version`: the app's own version; both apps start at `1.0.0` and move together.
- `platform`: `"windows"` or `"macos"`.
- `channels.<name>.printer`: the chosen printer, or `null` when none is chosen. When the chosen printer is
  no longer installed (`state` `"missing"`) it is a placeholder so the web can still name it: `id` and `name`
  both the configured id, `model` `""`, `connection` `"other"`, `kind` `"other"`, `papers` `[]`, `dpi` `0`,
  `state` `"offline"`, `default` `false`.
- `channels.<name>.state`: `"ready"`, `"busy"` (the queue is printing), `"paused"`, `"offline"`, `"error"`,
  `"missing"` (chosen printer no longer installed) or `"none"` (nothing chosen).

The web calls this to decide whether to offer printing (see CORS above for timeouts and failures). It says
what the app and its printers look like now; it never says whether a job printed.

### `GET /printers`

```json
{ "printers": [ { …Printer… }, … ] }
```

All printers the OS reports, except virtual ones: queues whose port or backend needs a dialog or is not a
device (Windows ports `PORTPROMPT:`, `FILE:`, `NUL` and `SHRFAX:`; macOS queues without a printing backend),
and queues whose name contains `PDF`, `XPS`, `Fax` or `OneNote` (case-insensitive), which catches the
third-party "print to PDF" drivers that sit on an ordinary port. A queue re-pointed at a real port or at a
local port with a fixed file path under a name of its own (as the CI tests do) is listed. Order: label
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
- `kind`: `"thermal"` for a label printer, `"other"` otherwise. A label printer is a queue whose driver
  reports at least one paper with a short edge of at most 4.25 in (108 mm) and reports neither Letter nor A4
  (office printers always list one of those; label drivers list none, even when they also list wide sizes
  for other models). Nothing else is guessed: no "laser", no "inkjet".
- `papers`: which of `"4x6"`, `"Letter"`, `"A4"` the driver reports. May be empty, which only means none of
  the three was listed, not that the printer refuses custom sizes.
- `dpi`: the queue's current print resolution as the driver reports it, `0` when unknown.
- `state`: `"ready"`, `"busy"`, `"paused"`, `"offline"` or `"error"`; `stateMessage` carries the OS text for
  `error`, else `""`. When the OS reports several things at once the first of `offline`, `error`, `paused`,
  `busy` wins; `ready` means the OS queue reports nothing in the way, not that the device is known to be on.
  A channel's state is the same list with `missing` (chosen printer not installed) ahead of `offline` and
  `none` when nothing is chosen; a job is refused for `missing`, `offline`, `error` and `paused` and queued
  for `busy`.
- `default`: the OS default printer.

### Page geometry

Both apps reduce a PDF page to the same visible box before anything else: the `CropBox` (the `MediaBox` when
there is none), with its origin moved to (0, 0), then turned by the page's own `/Rotate`. Width and height
are in PDF points (1/72 in); what the platform API hands back (Windows `PdfPage.Size` in DIPs at 1/96 in,
PDFKit `bounds(for:)` plus `rotation`) is converted to that. A page is landscape when that width is greater
than that height. Content outside the visible box is not drawn.

### `POST /print?channel=label|document&copies=1&title=…`

Body: either the document itself, `Content-Type: application/pdf`, `image/png` or `image/jpeg` (an image is
one page), at most 52,428,800 bytes (exactly that many is still accepted); or `Content-Type: application/json`
with `{"url": "https://…"}`, in which case the app downloads the document itself (http or https only,
redirects followed, 30 s timeout, the same size limit, the type sniffed from the bytes, not from the URL or
the response header) and prints it exactly as if the bytes had been posted. The web uses the URL form for
labels (whose files live on hosts the browser may not read from) and the bytes form for what it already
holds. `copies` defaults to 1 (1–99). `title` is the job name shown in the OS queue; defaults to
`NODE label` / `NODE document`.

- `label`: every page is printed as one 4 × 6 in label, portrait. A landscape page (see Page geometry) is
  rotated 90° clockwise first. The page is scaled to fit inside the printable area of the 4 × 6 in paper
  (aspect kept) and centred. The paper is set on the job, not in the printer's defaults; the app reads back
  the paper the driver settled on and refuses with `PRINT_FAILED` when it is not 4 × 6 in (within 0.08 in on
  either edge), rather than letting the driver print on whatever it fell back to.
- `document`: every page is printed on Letter, in the page's own orientation, scaled to fit the printable area
  and centred.

Copies: on `label` each page is repeated `copies` times in a row (A A B B); on `document` the whole document
is repeated (A B A B). The app expands the pages itself and submits one job with one copy.

A job takes its place in the channel's queue when its body has been received in full, and prints on the
printer chosen at that moment; jobs on one channel go to the OS one at a time, in that order, so a batch of
labels sent one request after another comes out in order. The response is sent once the OS spooler has
accepted the whole job, not when paper comes out. A timeout or a dropped connection does not mean nothing
printed, so the web never resends a job on its own.

```json
{ "job": { "channel": "label", "printer": "ZDesigner GX420d", "pages": 1, "copies": 1 } }
```

`printer` is the printer's display `name`; `pages` counts the pages of the document as sent, before copies.

Errors:

| status | code                  | when                                                   |
|--------|-----------------------|--------------------------------------------------------|
| 403    | `FORBIDDEN_ORIGIN`    | the `Origin` header is not an allowed origin           |
| 400    | `BAD_CHANNEL`         | `channel` is missing or not `label` / `document`       |
| 400    | `BAD_COPIES`          | `copies` is not 1–99                                   |
| 400    | `BAD_DOCUMENT`        | the body is not a PDF / PNG / JPEG the app can open, or has 0 pages |
| 400    | `BAD_URL`             | the JSON body has no `url`, or it is not http(s)                  |
| 502    | `FETCH_FAILED`        | the URL could not be downloaded (status, timeout, too large; `message` says) |
| 413    | `TOO_LARGE`           | body over 52,428,800 bytes                             |
| 409    | `NO_PRINTER`          | the channel has no printer chosen                      |
| 409    | `PRINTER_UNAVAILABLE` | chosen printer is missing, offline, in error or paused |
| 500    | `PRINT_FAILED`        | the OS or the printer refused the job (`message` says) |

Checks run in this order, the first failure answers: origin → channel → copies → size (a `Content-Length`
over the limit is `413` at once; a body without one is counted as it is read) → `NO_PRINTER` →
`PRINTER_UNAVAILABLE` → downloading (URL form) → opening the document → printing. A URL job takes its queue
place when its JSON body is in; the download happens in the queue, so a batch of URL jobs still prints in
arrival order. `title` is URL-decoded with `+` as a space.

Anything else is `404` with code `NOT_FOUND` or `405` with code `METHOD_NOT_ALLOWED`, both with a `message`.

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

Channel values are printer `id`s. On first run the app picks, among the printers `/printers` lists, the first
`thermal` one for `label` and the OS default printer (if listed and not thermal) for `document`, else leaves
the channel empty; the user can change both in the window.
