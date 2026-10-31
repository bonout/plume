#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=plume-nextcloud-test
PASSWORD=plume-demo-pass
OCC=(docker exec -u www-data "$NAME" php occ)
WORK=build/demo
CACHE=build/demo-cache
mkdir -p "$WORK" "$CACHE/photos"

docker ps --format '{{.Names}}' | grep -qx "$NAME" || { echo "Start scripts/test-server.sh first." >&2; exit 1; }
"${OCC[@]}" config:system:set skeletondirectory --value='' >/dev/null

photos=(
  "earthrise apollo|Earthrise|Lever de Terre"
  "blue marble earth|Blue Marble|La Bille bleue"
  "pillars of creation|Pillars of Creation|Piliers de la création"
  "saturn cassini rings|Saturn|Saturne"
  "aurora borealis from space station|Aurora from orbit|Aurore vue d'orbite"
  "carina nebula webb|Carina Nebula|Nébuleuse de la Carène"
  "jupiter juno|Jupiter|Jupiter"
  "mars surface perseverance|Mars|Mars"
  "full moon|Moon|Lune"
  "earth at night city lights|City lights|Lumières des villes"
)
for entry in "${photos[@]}"; do
  IFS='|' read -r query en _ <<<"$entry"
  file="$CACHE/photos/$en.jpg"
  [[ -s "$file" ]] && continue
  python3 - "$query" "$file" <<'PY'
import json, subprocess, sys, urllib.parse
query, target = sys.argv[1], sys.argv[2]
def get(url):
    return subprocess.run(["curl", "-sfL", "--max-time", "60", url.replace("http:", "https:", 1).replace(" ", "%20")],
                          capture_output=True, check=True).stdout
search = json.loads(get("https://images-api.nasa.gov/search?media_type=image&page_size=15&q=" + urllib.parse.quote(query)))
for item in search["collection"]["items"]:
    try:
        assets = json.loads(get(item["href"]))
    except Exception:
        continue
    for size in ("~large.jpg", "~medium.jpg", "~orig.jpg"):
        url = next((a for a in assets if a.endswith(size)), None)
        if not url:
            continue
        data = get(url.replace(" ", "%20"))
        if 150_000 < len(data) < 6_000_000:
            open(target, "wb").write(data)
            print("photo:", target.rsplit("/", 1)[-1], "from", item["data"][0]["nasa_id"])
            sys.exit(0)
        break
sys.exit("no usable photo for " + query)
PY
done
if [[ ! -s "$CACHE/orbit.mp4" ]]; then
  ffmpeg -loglevel error -y -i "$CACHE/photos/Blue Marble.jpg" \
    -vf "scale=2560:-2,zoompan=z='min(zoom+0.0015,1.3)':d=180:s=1280x720:fps=30,format=yuv420p" \
    -c:v libx264 "$CACHE/orbit.mp4"
fi

seed() { # user, locale, display name
  local user="$1" locale="$2" display="$3" root="$WORK/$2"
  if ! "${OCC[@]}" user:info "$user" >/dev/null 2>&1; then
    docker exec -u www-data -e OC_PASS="$PASSWORD" "$NAME" php occ user:add --password-from-env --display-name "$display" "$user" >/dev/null
  fi
  "${OCC[@]}" user:setting "$user" core lang "$locale" >/dev/null
  rm -rf "$root" && mkdir -p "$root"
  swift scripts/demo-files.swift "$root" "$locale"
  local photos_dir archive scans video moodboard
  if [[ "$locale" == fr ]]; then
    photos_dir="Photos/Espace"; archive="Archives/Numérisations 2015-2025"; scans="Numérisation"
    video="Photos/La Terre en orbite.mp4"; moodboard="Projets/Refonte du site/Moodboard.jpg"
  else
    photos_dir="Photos/Space"; archive="Archive/Scans 2015-2025"; scans="Scan"
    video="Photos/Earth from orbit.mp4"; moodboard="Projects/Website redesign/Moodboard.jpg"
  fi
  mkdir -p "$root/$photos_dir"
  for entry in "${photos[@]}"; do
    IFS='|' read -r _ en fr <<<"$entry"
    cp "$CACHE/photos/$en.jpg" "$root/$photos_dir/$([[ "$locale" == fr ]] && echo "$fr" || echo "$en").jpg"
  done
  cp "$CACHE/photos/Carina Nebula.jpg" "$root/$moodboard"
  cp "$CACHE/orbit.mp4" "$root/$video"
  local files="/var/www/html/data/$user/files"
  docker exec "$NAME" sh -c "rm -rf '$files' && mkdir -p '$files'"
  python3 - "$root" <<'PY' | docker exec -i "$NAME" tar -x -C "$files"
import os, sys, tarfile, unicodedata
root = sys.argv[1]
with tarfile.open(fileobj=sys.stdout.buffer, mode="w|") as tar:
    for folder, _, names in os.walk(root):
        for name in names:
            path = os.path.join(folder, name)
            tar.add(path, arcname=unicodedata.normalize("NFC", os.path.relpath(path, root)))
PY
  local sample
  sample=$(find "$root" -name '*.pdf' | head -1)
  docker cp "$sample" "$NAME:/tmp/scan.pdf"
  docker exec "$NAME" sh -c "mkdir -p '$files/$archive' && cd '$files/$archive' &&
    i=1; while [ \$i -le 10000 ]; do cp /tmp/scan.pdf \"$scans \$(printf %05d \$i).pdf\"; i=\$((i+1)); done"
  docker exec "$NAME" sh -c "cd '$files' && find . -type f ! -path './${archive%%/*}/*' | while read -r f; do
      touch -d \"@\$(( $(date +%s) - (\$(cksum \"\$f\" | cut -d' ' -f1) % 5184000) ))\" \"\$f\"; done
    chown -R www-data:www-data /var/www/html/data/$user"
  "${OCC[@]}" files:scan --path="$user/files" >/dev/null
  echo "$user: seeded ($locale)"
}

seed demo en "Alex Martin"
seed demo-fr fr "Camille Laurent"

if [[ -n "${PLUME_DEMO_BIG:-}" ]]; then
  big="/var/www/html/data/admin/files/Big folder"
  docker exec "$NAME" sh -c "mkdir -p '$big' && cd '$big' && i=1; while [ \$i -le $PLUME_DEMO_BIG ]; do
    printf x > \"File \$(printf %06d \$i).txt\"; i=\$((i+1)); done; chown -R www-data:www-data '$big'"
  "${OCC[@]}" files:scan --path="admin/files/Big folder" >/dev/null
  echo "admin: Big folder with $PLUME_DEMO_BIG files"
fi
