#!/usr/bin/env python3
"""
GreenZones-Pipeline: OSM-GeoJSON → Verbotszonen-GeoJSON (§5 KCanG).

Input:  GeoJSON aus `osmium export` (gefilterte Schutzobjekte + Fußgängerzonen)
Output: ban.geojson  — 100m-Buffer um Schulen/Kitas/Spielplätze/Sportstätten (dissolved)
        time.geojson — Fußgängerzonen (7–20 Uhr), Linien als ~8m-Fläche

Läuft regionsunabhängig (Niedersachsen heute, DE später) — Geometrie wird in
EPSG:3857 gebuffert (Fehler <1% in DE-Breiten, für 100m-Radius irrelevant),
Ausgabe wieder WGS84.
"""
import json
import math
import sys
from pathlib import Path

from pyproj import Transformer
from shapely.geometry import shape, mapping
from shapely.ops import transform
from shapely import union_all

BAN_KEYS = {
    ("amenity", "school"),
    ("amenity", "kindergarten"),
    ("leisure", "playground"),
    ("leisure", "pitch"),
    ("leisure", "sports_centre"),
    ("leisure", "stadium"),
    ("leisure", "swimming_pool"),
}
BUFFER_M = 100.0
PEDESTRIAN_LINE_HALFWIDTH_M = 8.0

TO_M = Transformer.from_crs("EPSG:4326", "EPSG:3857", always_xy=True).transform
TO_DEG = Transformer.from_crs("EPSG:3857", "EPSG:4326", always_xy=True).transform


def classify(props):
    if props.get("highway") == "pedestrian":
        return "time"
    for k, v in BAN_KEYS:
        if props.get(k) == v:
            return "ban"
    return None


def main(src, out_dir):
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    ban_geoms, time_geoms = [], []
    skipped = 0
    with open(src) as f:
        fc = json.load(f)

    total = len(fc["features"])
    for i, feat in enumerate(fc["features"]):
        if i % 100_000 == 0:
            print(f"progress {i}/{total}", flush=True)
        cls = classify(feat.get("properties") or {})
        if cls is None:
            skipped += 1
            continue
        try:
            raw = shape(feat["geometry"])
            g = transform(TO_M, raw)
        except Exception:
            skipped += 1
            continue
        # Web-Mercator streckt Distanzen um 1/cos(lat) — Buffer-Radius mitskalieren,
        # sonst sind die Zonen real um cos(lat) zu klein (~62 m statt 100 m bei 52°N).
        lat = raw.centroid.y
        scale = 1.0 / max(0.2, math.cos(math.radians(lat)))
        if cls == "ban":
            ban_geoms.append(g.buffer(BUFFER_M * scale, quad_segs=8))
        else:
            # Fußgängerzone: Fläche direkt, Linie → schmale Fläche
            if g.geom_type in ("LineString", "MultiLineString"):
                g = g.buffer(PEDESTRIAN_LINE_HALFWIDTH_M * scale, quad_segs=4)
            elif g.geom_type in ("Polygon", "MultiPolygon"):
                pass
            else:
                skipped += 1
                continue
            time_geoms.append(g)

    print(f"features total={total} ban={len(ban_geoms)} time={len(time_geoms)} skipped={skipped}", flush=True)
    if not ban_geoms and not time_geoms:
        sys.exit("FEHLER: keine Zonen extrahiert — Filter/Input prüfen")

    for name, geoms in (("ban", ban_geoms), ("time", time_geoms)):
        print(f"union {name}: {len(geoms)} geoms …", flush=True)
        # grid_size aktiviert den fixed-precision Overlay (GEOS ≥3.9) — massiv schneller,
        # 0.5 m Präzision ist bei 100 m-Zonen + simplify(1.0) irrelevant.
        merged = union_all(geoms, grid_size=0.5) if geoms else None
        feats = []
        if merged is not None:
            merged = merged.simplify(1.0)  # 1m Toleranz, unsichtbar bei Zoom ≤ 18
            parts = merged.geoms if merged.geom_type == "MultiPolygon" else [merged]
            feats = [
                {"type": "Feature", "properties": {"kind": name}, "geometry": mapping(transform(TO_DEG, p))}
                for p in parts
            ]
        out = out_dir / f"{name}.geojson"
        with open(out, "w") as f:
            json.dump({"type": "FeatureCollection", "features": feats}, f)
        print(f"{out}: {len(feats)} Polygone")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: build_zones.py <osmium-export.geojson> <out-dir>")
    main(sys.argv[1], sys.argv[2])
