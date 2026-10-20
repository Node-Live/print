#!/bin/bash
# Runs the packed app on the CI queues and goes once through the local protocol: both channels print (the jobs
# reach the CUPS queues), an image is posted and a document is fetched from a plain-http host name (so App Transport
# Security in the packed app is exercised), a foreign origin is refused. One job per queue: once a backend has tried
# the missing device the queue may report it offline, and the app then rightly refuses the next job.
set -euo pipefail
app=$1
testdata=$2
echo "127.0.0.1 files.node-print.test" | sudo tee -a /etc/hosts > /dev/null
python3 -m http.server 8123 --bind 127.0.0.1 --directory "$testdata" > /dev/null 2>&1 &
files=$!
"$app/Contents/MacOS/NODE Print" &
pid=$!
trap 'kill $pid $files' EXIT
for _ in $(seq 1 30); do
  sleep 0.5
  curl -sf http://127.0.0.1:19233/status > /dev/null && break
done
set -x
curl -sf http://127.0.0.1:19233/status
curl -sf http://127.0.0.1:19233/printers
sips -s format png "$testdata/../macos/Resources/AppIcon.icns" --out /tmp/icon.png > /dev/null
curl -s --fail-with-body -X POST -H "Content-Type: image/png" --data-binary @/tmp/icon.png "http://127.0.0.1:19233/print?channel=label&copies=2&title=CI+label"
curl -s --fail-with-body -X POST -H "Content-Type: application/json" --data '{"url":"http://files.node-print.test:8123/zpl/corner-landscape-4x6-203.pdf"}' "http://127.0.0.1:19233/print?channel=document&title=CI+document"
test "$(curl -s -o /dev/null -w '%{http_code}' -H 'Origin: https://nrp.node.live' -X OPTIONS http://127.0.0.1:19233/print)" = 204
test "$(curl -s -o /dev/null -w '%{http_code}' -H 'Origin: https://evil.example' -X POST --data-binary @"$testdata/zpl/border-4x6-203.pdf" 'http://127.0.0.1:19233/print?channel=label')" = 403
lpstat -o
test "$(lpstat -o | wc -l)" -ge 2
cancel -a Rollo_X1038 Brother_HL_L2350DW
lsof -nP -iTCP:19233 -sTCP:LISTEN
