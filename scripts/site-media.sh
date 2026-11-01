#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
RAW=${1:-build/screenshots/raw}
convert() {
  local source="$1" target="$2" width="$3"
  [ -f "$source" ] || { echo "missing $source"; return; }
  sips --resampleWidth "$width" -s format jpeg -s formatOptions 82 "$source" --out "$target" >/dev/null
  echo "$target"
}
for pair in en:en-US fr:fr-FR; do
  lang=${pair%%:*} locale=${pair#*:}
  out=docs/screenshots/$lang
  mkdir -p "$out"
  for shot in 01-browse:browse 02-search:search 03-files-app:files-app 04-offline:offline 05-quick-look:quick-look 06-save-from-any-app:save; do
    convert "$RAW/$locale/iPhone 17 Pro Max-${shot%%:*}.png" "$out/iphone-${shot#*:}.jpg" 660
  done
  convert "$RAW/$locale/iPad Pro 13-inch (M5)-01-browse.png" "$out/ipad-browse.jpg" 1032
  for shot in 01-browse:browse 02-search:search 04-offline:offline; do
    convert "$RAW/$locale/Mac-${shot%%:*}.png" "$out/mac-${shot#*:}.jpg" 1600
  done
done
