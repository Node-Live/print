#!/bin/bash
# Runs the packed app on the CI queues and goes once through the local protocol, checking that a ZPL label reaches
# the printer's socket byte for byte.
set -euo pipefail
app=$1
testdata=$2
config="$HOME/Library/Application Support/NODE Print"
mkdir -p "$config"
echo '{"channels":{"label":"Zebra_GX420d","document":"Brother_HL_L2350DW"},"allowedOrigins":[],"launchAtLogin":false}' > "$config/config.json"

"$app/Contents/MacOS/NODE Print" &
pid=$!
trap 'kill $pid' EXIT
for _ in $(seq 1 30); do
  sleep 0.5
  curl -sf http://127.0.0.1:19233/status > /dev/null && break
done

nc -l 127.0.0.1 9100 > /tmp/zpl-received &
listener=$!
set -x
curl -sf http://127.0.0.1:19233/status
curl -sf http://127.0.0.1:19233/printers
curl -sf -X POST -H "Content-Type: application/pdf" --data-binary @"$testdata/zpl/border-4x6-203.pdf" "http://127.0.0.1:19233/print?channel=label&copies=2&title=CI+label"
curl -sf -X POST -H "Content-Type: application/pdf" --data-binary @"$testdata/zpl/border-4x6-203.pdf" "http://127.0.0.1:19233/print?channel=document&title=CI+document"
curl -s -o /dev/null -w "%{http_code}\n" -H "Origin: https://nrp.node.live" -X OPTIONS http://127.0.0.1:19233/print
for _ in $(seq 1 40); do
  sleep 0.5
  kill -0 $listener 2> /dev/null || break
done
python3 - "$testdata/zpl/border-4x6-203.json" /tmp/zpl-received <<'PY'
import json, sys
v = json.load(open(sys.argv[1]))
per_row = (v["width"] + 7) // 8
total = per_row * v["length"]
expected = f"^XA\n^PW{v['width']}\n^LL{v['length']}\n^LH0,0\n^FO0,0^GFA,{total},{total},{per_row},{v['data']}^FS\n^PQ2,0,1,Y\n^XZ\n"
received = open(sys.argv[2], "rb").read().decode("ascii")
print(f"ZPL received {len(received)} bytes, expected {len(expected)}")
sys.exit(0 if received == expected else 1)
PY
lpstat -o
cancel -a Brother_HL_L2350DW
lsof -nP -iTCP:19233 -sTCP:LISTEN
