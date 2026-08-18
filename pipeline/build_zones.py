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
from collections import Counter
from pathlib import Path

from pyproj import Transformer
from shapely.geometry import shape, mapping
from shapely.ops import transform
from shapely import union_all

# Kanonische Tag-Liste. `run.sh` fragt sie mit `--osmium-filter` ab, statt eine
# zweite Fassung zu pflegen — ein Tag, das hier steht und dort fehlte, käme sonst
# nie im GeoJSON an und der Filter liefe still ins Leere.
BAN_KEYS = {
    # Schulen und Kindereinrichtungen (§5 Abs. 2 Nr. 1 KCanG)
    ("amenity", "school"),
    ("amenity", "kindergarten"),
    ("amenity", "childcare"),          # Kindertagespflege
    # Öffentlich zugängliche Sportstätten
    ("leisure", "playground"),
    ("leisure", "pitch"),
    ("leisure", "sports_centre"),
    ("leisure", "sports_hall"),
    ("leisure", "stadium"),
    ("leisure", "swimming_pool"),
    ("leisure", "water_park"),
    ("leisure", "track"),              # Laufbahn / Radrennbahn
    ("leisure", "fitness_centre"),     # Studio — öffentlich zugänglich gegen Entgelt
    ("leisure", "fitness_station"),    # Trimm-dich, Calisthenics
    ("leisure", "horse_riding"),
    ("leisure", "ice_rink"),
    ("leisure", "golf_course"),
    ("leisure", "summer_camp"),        # Ferienlager
}

# Sammelbegriffe, die erst durch ihren Zweck zur Kinder-/Jugendeinrichtung werden.
# `amenity=youth_centre` ist in Deutschland praktisch ungenutzt (3 Objekte
# bundesweit) — Jugendzentren hängen an community_centre + `:for`.
FOR_KEYS = {
    ("amenity", "community_centre"): "community_centre:for",
    ("amenity", "social_facility"): "social_facility:for",
}
FOR_VALUES = {"child", "children", "juvenile", "youth", "teenager", "pupil"}

BUFFER_M = 100.0
PEDESTRIAN_LINE_HALFWIDTH_M = 8.0

TO_M = Transformer.from_crs("EPSG:4326", "EPSG:3857", always_xy=True).transform
TO_DEG = Transformer.from_crs("EPSG:3857", "EPSG:4326", always_xy=True).transform


def classify(props):
    """Gibt (Klasse, Herkunfts-Tag) zurück — das Tag trägt die Zählung je Sorte."""
    if props.get("highway") == "pedestrian":
        return "time", "highway=pedestrian"
    for k, v in BAN_KEYS:
        if props.get(k) == v:
            return "ban", f"{k}={v}"
    for (k, v), for_key in FOR_KEYS.items():
        if props.get(k) != v:
            continue
        # `:for` ist eine Semikolon-Liste: „child;senior"
        purposes = {p.strip() for p in (props.get(for_key) or "").split(";")}
        if purposes & FOR_VALUES:
            return "ban", f"{k}={v}[{for_key}]"
    return None, None


def osmium_filter_lines():
    """Vorfilter für `osmium tags-filter`, aus derselben Quelle wie classify().

    Bewusst großzügiger als classify(): community_centre/social_facility kommen
    vollständig durch, die `:for`-Entscheidung fällt erst in Python.
    """
    by_key = {}
    for k, v in sorted(BAN_KEYS) + sorted(FOR_KEYS):
        by_key.setdefault(k, []).append(v)
    lines = [f"nwr/{k}={','.join(sorted(vs))}" for k, vs in sorted(by_key.items())]
    lines.append("w/highway=pedestrian")
    return lines


def main(src, out_dir):
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    ban_geoms, time_geoms = [], []
    skipped = 0
    per_tag = Counter()
    with open(src) as f:
        fc = json.load(f)

    total = len(fc["features"])
    for i, feat in enumerate(fc["features"]):
        if i % 100_000 == 0:
            print(f"progress {i}/{total}", flush=True)
        cls, tag = classify(feat.get("properties") or {})
        if cls is None:
            skipped += 1
            continue
        per_tag[tag] += 1
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
    print("Treffer je Sorte:", flush=True)
    for tag, n in per_tag.most_common():
        print(f"  {n:8d}  {tag}", flush=True)
    # Eine Sorte ohne einen einzigen Treffer heißt: Vorfilter, Schreibweise oder
    # Annahme stimmt nicht. Das darf nicht still durchlaufen.
    expected = {f"{k}={v}" for k, v in BAN_KEYS}
    expected |= {f"{k}={v}[{f}]" for (k, v), f in FOR_KEYS.items()}
    expected.add("highway=pedestrian")
    leer = sorted(expected - set(per_tag))
    if leer:
        print(f"WARNUNG: ohne Treffer: {', '.join(leer)}", flush=True)
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
    if len(sys.argv) == 2 and sys.argv[1] == "--osmium-filter":
        print("\n".join(osmium_filter_lines()))
        sys.exit(0)
    if len(sys.argv) != 3:
        sys.exit("usage: build_zones.py <osmium-export.geojson> <out-dir>\n"
                 "       build_zones.py --osmium-filter")
    main(sys.argv[1], sys.argv[2])
