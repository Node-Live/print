#!/bin/bash
# Starts the packed app in each window style and language on a fresh config and captures the real window
# (title bar and materials included) into $2/<style>/.
set -euo pipefail
app=$1
out=$2
binary="$app/Contents/MacOS/NODE Print"
crash_reports() {
  for report in "$HOME"/Library/Logs/DiagnosticReports/NODE*; do
    [ -e "$report" ] && head -c 8000 "$report"
  done
  return 0
}
trap crash_reports EXIT
swiftc -O "$(dirname "$0")/window-id.swift" -o /tmp/window-id

capture() { # style language file [extra env]
  rm -rf "$HOME/Library/Application Support/NODE Print"
  env ${4:-} "$binary" --style "$1" -AppleLanguages "($2)" &
  local pid=$!
  local id=""
  for _ in $(seq 1 30); do
    sleep 0.5
    id=$(/tmp/window-id "NODE Print" || true)
    [ -n "$id" ] && break
  done
  sleep 2
  [ -n "$id" ] && [ -n "$3" ] && screencapture -o -x -l "$id" "$3"
  sleep 1
  kill "$pid" 2> /dev/null || true
  wait "$pid" || true
}

for style in design native; do
  mkdir -p "$out/$style"
  for language in en zh-Hans es; do
    capture "$style" "$language" "$out/$style/main-window-$style-$language.png"
  done
done

# The runner's display is 1x; a 2x render of the design content shows the type in detail (layout only, no glass).
capture design en "" "NODE_PRINT_SNAPSHOT=$out/design/main-window-design-en-content@2x.png"

swiftc -O "$(dirname "$0")/glass-variants.swift" -o /tmp/glass-variants
/tmp/glass-variants &
pid=$!
sleep 3
id=$(/tmp/window-id glass-variants || true)
[ -n "$id" ] && screencapture -o -x -l "$id" "$out/design/glass-variants.png"
kill "$pid" 2> /dev/null || true
wait "$pid" || true
ls -la "$out"/*
