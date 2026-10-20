#!/bin/bash
# Starts the packed app once per language on a fresh config and captures its window into $2.
set -euo pipefail
app=$1
out=$2
binary="$app/Contents/MacOS/NODE Print"
mkdir -p "$out"
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
    kill "$pid"
    wait "$pid" || true
    NODE_PRINT_SNAPSHOT="$out/main-window-$language-rendered.png" "$binary" -AppleLanguages "($language)" &
    pid=$!
    sleep 5
  fi
  kill "$pid"
  wait "$pid" || true
done
ls -la "$out"
