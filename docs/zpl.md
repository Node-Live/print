# Labels on ZPL printers

**Parked: not part of v1.** Labels reach Zebra printers through their driver like any other printer. This
is the design for a later version, kept so the vectors in `testdata/zpl/` and the thinking are not lost.

Zebra label printers (the warehouses mostly run them; the test unit is a GX420d) take ZPL, their own command
language, straight from the host. NODE Print would send ZPL to them instead of going through the driver's
paper settings, so a label comes out at the printer's own dots with nothing scaled, dithered or cut off by a
mis-set driver. Both apps implement this the same way; `testdata/zpl/` holds vectors they must both pass.

Known gaps to close before this ships: a `^GF` field holds at most 99,999 bytes, so a 4 × 6 bitmap must be
cut into horizontal strips of `floor(99999 / bytesPerRow)` rows, each its own `^FO0,<y>^GFA…^FS` with the
row-repeat `:` never crossing a strip; the job should pin `^PON^PMN^LRN` so a previous job's orientation,
mirror or reverse setting cannot leak in; and a queue is only ZPL on explicit evidence (`CMD:…ZPL…` in the
1284 id or a ZPL driver), never on the Zebra name alone.

## Which queues count as ZPL

- Windows: the driver name starts with `ZDesigner` and does not contain `(EPL)` or `(CPCL)`; or the driver
  name contains `ZPL`.
- macOS: the queue's PPD / IPP make-and-model contains `Zebra` or `ZPL`, or its IEEE 1284 device id has
  `CMD:` containing `ZPL`. A queue whose name or make-and-model says `EPL` or `CPCL` without `ZPL` (such as
  the built-in "Zebra CPCL Label Printer" driver) is not ZPL.

Everything else prints through the OS driver.

## Resolution

Use the driver's reported resolution (Windows `DeviceCapabilities(DC_ENUMRESOLUTIONS)` / the DC's
`LOGPIXELSX`; macOS the queue's default `printer-resolution` or PPD `DefaultResolution`). A ZPL printer that
reports nothing is 203 dpi. Only 203 and 300 occur in practice; treat any other value as reported.

| dpi | label width (dots) | label length (dots) |
|-----|--------------------|---------------------|
| 203 | 812                | 1218                |
| 300 | 1200               | 1800                |

(`4 × dpi` by `6 × dpi`.)

## From a PDF page to dots

1. Rotate a landscape page (width > height in points) 90° clockwise so it is portrait.
2. Render the page onto a white canvas of `width × length` dots: scale to fit (aspect kept), centre, with
   anti-aliasing on. Render at the exact dot size; do not render larger and downsample.
3. Convert to 1 bit by luminance threshold: a dot prints (bit = 1) when `0.299 R + 0.587 G + 0.114 B < 128`.
   No dithering: labels are text, lines and barcodes, and a dithered barcode scans badly.
4. Pack rows left to right, most significant bit first, `bytesPerRow = ceil(width / 8)`, unused bits in the
   last byte 0.

## The ZPL job

One `^XA … ^XZ` block per label, `copies` labels via `^PQ`:

```
^XA
^PW812
^LL1218
^LH0,0
^FO0,0^GFA,<total>,<total>,<bytesPerRow>,<data>^FS
^PQ1,0,1,Y
^XZ
```

- `<total>` = `bytesPerRow × length`.
- `<data>` is the bitmap in ZPL's ASCII compression (below), ending with the last row; no trailing newline
  inside the field.
- No `^MD`, `^MN`, `^MT`, `^PR` or other printer settings: darkness, media sensing and speed stay whatever the
  printer is configured to.
- Lines end with `\n`. The whole job is ASCII.

A multi-page PDF is one job with one `^XA … ^XZ` block per page, in page order, each with its own `^PQ`.

## ASCII compression (`^GFA` data)

The raw form is two hex digits per byte, one line per row. ZPL's compression shortens runs of the same hex
digit and repeated rows; every ZPL II printer accepts it. Encode each row left to right:

- A run of the same hex digit `n` times (`n ≥ 1`) is written as a count prefix followed by the digit once.
  The count prefix is empty for `n = 1`; otherwise it is the letters whose values add up to `n`, largest
  first: `z` = 400, `y` = 380, `x` = 360 … `h` = 40, `g` = 20 (lower case, 20 each step down), then
  `Y` = 19, `X` = 18 … `H` = 2, `G` = 1. So 3 → `I`, 20 → `g`, 44 → `hJ`, 823 → `zzgI`.
- A run that reaches the end of the row with digit `0` is written as `,` (comma) instead of its count and
  digit; a run that reaches the end with digit `F` is written as `!`.
- A row identical to the previous row is written as `:` on its own.
- Rows are not separated by anything; the encoded rows are simply concatenated (`,`, `!` and `:` mark where a
  row ends; a row written out in full ends after exactly `bytesPerRow × 2` hex digits have been covered).
- Hex digits are upper case.

## Sending

- Windows: `OpenPrinter` → `StartDocPrinter` with datatype `RAW` → `WritePrinter` → `EndDocPrinter`. The
  ZDesigner driver passes RAW through unchanged, for USB and network queues alike.
- macOS: a raw job on the queue (`cupsCreateJob` with format `application/vnd.cups-raw`, or `lp -o raw`),
  which CUPS passes to the backend unchanged.

## Test vectors

`testdata/zpl/*.json`, one case each:

```json
{
  "name": "...",
  "dpi": 203,
  "width": 16, "length": 4,
  "rows": ["FF00", "FF00", "0000", "FFFF"],
  "data": "HF,:,!"
}
```

`rows` are the packed rows in hex (test-sized bitmaps, so `width`/`length` here are the bitmap's, not a 4 × 6
label); `data` is the exact compressed field. Both apps must produce `data` from `rows` byte for byte, and
the job text around it as in the template above with the vector's `width`/`length`/`bytesPerRow`.

`testdata/zpl/*.pdf` are 4 × 6 pages (blank, a black border, a landscape page with a corner mark) with a
vector of the same name: rendering the PDF at the vector's `dpi` by the steps above must give exactly the
vector's `rows`. The landscape one pins the rotation direction.
