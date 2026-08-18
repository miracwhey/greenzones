#!/usr/bin/env bash
# GreenZones-Pipeline: PBF → zones.pmtiles
# usage: ./run.sh <extract.osm.pbf> <out-dir>
set -euo pipefail

PBF="$1"
OUT="$2"
DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_PY="$DIR/../.venv/bin/python"

mkdir -p "$OUT"

echo "== 1/4 osmium tags-filter =="
# Der Filter kommt aus build_zones.py — dort steht die einzige Tag-Liste.
FILTER=()
while IFS= read -r line; do
  [ -n "$line" ] && FILTER+=("$line")
done < <("$VENV_PY" "$DIR/build_zones.py" --osmium-filter)
if [ ${#FILTER[@]} -eq 0 ]; then
  echo "FEHLER: build_zones.py --osmium-filter lieferte nichts" >&2
  exit 1
fi
printf '   %s\n' "${FILTER[@]}"
osmium tags-filter "$PBF" "${FILTER[@]}" \
  -o "$OUT/filtered.osm.pbf" --overwrite

echo "== 2/4 osmium export =="
osmium export "$OUT/filtered.osm.pbf" \
  -o "$OUT/filtered.geojson" --overwrite \
  --geometry-types=point,linestring,polygon

echo "== 3/4 buffer + dissolve =="
"$VENV_PY" "$DIR/build_zones.py" "$OUT/filtered.geojson" "$OUT"

echo "== 4/4 tippecanoe =="
tippecanoe -o "$OUT/zones.pmtiles" --force \
  --minimum-zoom=6 --maximum-zoom=14 \
  --simplification=4 --detect-shared-borders \
  --no-tile-size-limit \
  -L ban:"$OUT/ban.geojson" \
  -L time:"$OUT/time.geojson"

ls -lh "$OUT/zones.pmtiles"
echo "OK"
