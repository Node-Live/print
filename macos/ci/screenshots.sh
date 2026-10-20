#!/bin/bash
# Starts the packed app once per language on a fresh config and captures its window into $2.
set -euo pipefail
app=$1
out=$2
binary="$app/Contents/MacOS/NODE Print"
mkdir -p "$out"
crash_reports() {
  for report in "$HOME"/Library/Logs/DiagnosticReports/NODE*; do
    [ -e "$report" ] && head -c 8000 "$report"
  done
  return 0
}
trap crash_reports EXIT
swiftc -O "$(dirname "$0")/window-id.swift" -o /tmp/window-id

for language in en zh-Hans es; do
  rm -rf "$HOME/Library/Application Support/NODE Print"
  "$binary" -AppleLanguages "($language)" &
  pid=$!
  id=""
  for _ in $(seq 1 30); do
    sleep 0.5
    id=$(/tmp/window-id "NODE Print" || true)
    [ -n "$id" ] && break
  done
  sleep 2
  if [ -z "$id" ] || ! screencapture -o -x -l "$id" "$out/main-window-$language.png"; then
    echo "screencapture failed for $language; rendering the root view instead"
    kill "$pid" 2> /dev/null || true
    wait "$pid" || true
    NODE_PRINT_SNAPSHOT="$out/main-window-$language-rendered.png" "$binary" -AppleLanguages "($language)" &
    pid=$!
    sleep 5
  fi
  kill "$pid" 2> /dev/null || true
  wait "$pid" || true
done

# The runner's display is 1x; a 2x render of the window content shows the type in detail (without the glass).
rm -rf "$HOME/Library/Application Support/NODE Print"
NODE_PRINT_SNAPSHOT="$out/main-window-en-content@2x.png" "$binary" -AppleLanguages "(en)" &
pid=$!
sleep 5
kill "$pid" 2> /dev/null || true
wait "$pid" || true
swiftc -O "$(dirname "$0")/glass-variants.swift" -o /tmp/glass-variants
/tmp/glass-variants &
pid=$!
sleep 3
id=$(/tmp/window-id glass-variants || true)
[ -n "$id" ] && screencapture -o -x -l "$id" "$out/glass-variants.png"
kill "$pid" 2> /dev/null || true
wait "$pid" || true
ls -la "$out"

