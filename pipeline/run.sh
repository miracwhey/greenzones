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
osmium tags-filter "$PBF" \
  nwr/amenity=school,kindergarten \
  nwr/leisure=playground,pitch,sports_centre,stadium,swimming_pool \
  w/highway=pedestrian \
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
