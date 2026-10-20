#!/bin/bash
# Starts the packed app in each window style and language on a fresh config and captures the real window
# (title bar and materials included) into $2/<style>/.
set -euo pipefail
app="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
mkdir -p "$2"
out=$(cd "$2" && pwd)
crash_reports() {
  for report in "$HOME"/Library/Logs/DiagnosticReports/NODE*; do
    [ -e "$report" ] && head -c 8000 "$report"
  done
  return 0
}
trap crash_reports EXIT
swiftc -O "$(dirname "$0")/window-id.swift" -o /tmp/window-id

# Launched through LaunchServices so the window comes up active, as a user would see it.
capture() { # style language file
  rm -rf "$HOME/Library/Application Support/NODE Print"
  open -n "$app" --args --style "$1" -AppleLanguages "($2)"
  local id=""
  for _ in $(seq 1 30); do
    sleep 0.5
    id=$(/tmp/window-id "NODE Print" || true)
    [ -n "$id" ] && break
  done
  # A launch right after the previous copy quit does not always come to the front; opening the running app does.
  open -a "$app"
  sleep 2
  [ -n "$id" ] && screencapture -o -x -l "$id" "$3"
  sleep 1
  for pid in $(pgrep -x "NODE Print"); do kill "$pid"; done
  while pgrep -x "NODE Print" > /dev/null; do sleep 0.2; done
}

for style in design native; do
  mkdir -p "$out/$style"
  for language in en zh-Hans es; do
    capture "$style" "$language" "$out/$style/main-window-$style-$language.png"
  done
done

ls -la "$out"/*
