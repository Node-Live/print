#!/bin/bash
# Runs the packed app on the CI queues and goes once through the local protocol: both channels print (the jobs
# reach the CUPS queues), an image prints, a foreign origin is refused. One job per queue: once a backend has tried
# the missing device the queue may report it offline, and the app then rightly refuses the next job.
set -euo pipefail
app=$1
testdata=$2
"$app/Contents/MacOS/NODE Print" &
pid=$!
trap 'kill $pid' EXIT
for _ in $(seq 1 30); do
  sleep 0.5
  curl -sf http://127.0.0.1:19233/status > /dev/null && break
done
set -x
curl -sf http://127.0.0.1:19233/status
curl -sf http://127.0.0.1:19233/printers
sips -s format png "$testdata/../macos/Resources/AppIcon.icns" --out /tmp/icon.png > /dev/null
curl -s --fail-with-body -X POST -H "Content-Type: image/png" --data-binary @/tmp/icon.png "http://127.0.0.1:19233/print?channel=label&copies=2&title=CI+label"
curl -s --fail-with-body -X POST -H "Content-Type: application/pdf" --data-binary @"$testdata/zpl/corner-landscape-4x6-203.pdf" "http://127.0.0.1:19233/print?channel=document&title=CI+document"
test "$(curl -s -o /dev/null -w '%{http_code}' -H 'Origin: https://nrp.node.live' -X OPTIONS http://127.0.0.1:19233/print)" = 204
test "$(curl -s -o /dev/null -w '%{http_code}' -H 'Origin: https://evil.example' -X POST --data-binary @"$testdata/zpl/border-4x6-203.pdf" 'http://127.0.0.1:19233/print?channel=label')" = 403
lpstat -o
test "$(lpstat -o | wc -l)" -ge 2
cancel -a Rollo_X1038 Brother_HL_L2350DW
lsof -nP -iTCP:19233 -sTCP:LISTEN
