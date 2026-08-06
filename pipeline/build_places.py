#!/usr/bin/env python3
"""
GreenZones-Pipeline: OSM-PBF → places.json (Offline-Ortsindex für die Adresssuche).

Input:  germany-latest.osm.pbf
Output: places.json — {"v":1,"places":[{"n","t","s","c"?,"lat","lng"}, …]}

Indiziert werden zwei Sorten Einträge:
  * Orte      — place-Nodes: city, town, village, hamlet, suburb, quarter, neighbourhood
  * Aufenthalts-POIs — Plätze (place=square UND highway=pedestrian-Flächen),
    Parks, Seen, Stadtwälder (natural=wood/landuse=forest ab 30 ha),
    Bahnhöfe (Ways/Relationen als Fläche,
    Koordinate = representative_point). Die App beantwortet „darf ich HIER
    konsumieren?", gesucht wird also auch nach „Küchengarten" oder „Maschsee".

Ablauf:
  1. osmium tags-filter: Orts-Nodes + POIs + Verwaltungs-Relationen (admin_level 4/6/8)
     in EINEM Lauf über die 4,5-GB-Datei.
  2. osmium export: Nodes → Punkte, Ways/Relationen → Polygone (je als GeoJSON-Seq).
  3. Zuordnung per Point-in-Polygon (shapely STRtree):
       jeder Eintrag        → Bundesland (admin_level=4) als Feld `s`
       Stadtteile und POIs  → Gemeinde   (admin_level=8) als Feld `c`

Kreisfreie Städte (München, Köln, Dresden …) haben in OSM keine admin_level=8-,
sondern nur eine admin_level=6-Relation — ohne diesen Fallback bliebe rund ein
Drittel aller Stadtteile ohne Parent. Landkreise (ebenfalls Level 6) greifen nie,
weil dort immer schon eine Level-8-Gemeinde trifft.

Die osmium-Zwischendateien landen in data/ und werden wiederverwendet, wenn sie
schon existieren — der PBF-Lauf ist der teure Teil.
"""
import json
import math
import subprocess
import sys
from pathlib import Path

from pyproj import Geod
from shapely import STRtree, points as make_points
from shapely.geometry import shape

PLACE_TYPES = ["city", "town", "village", "hamlet", "suburb", "quarter", "neighbourhood"]
PLACE_SET = set(PLACE_TYPES)
CHILD_TYPES = {"suburb", "quarter", "neighbourhood"}
POI_TYPES = {"square", "park", "water", "station", "wood"}
PARENT_TYPES = CHILD_TYPES | POI_TYPES  # bekommen ein `c`-Feld
# Stillgewässer; Fluss-/Kanalflächen (water=river|canal|ditch …) sind keine Aufenthaltsorte.
STILL_WATER = {"lake", "pond", "reservoir", "oxbow", "lagoon"}
# Stadtwälder ab 30 ha; darunter sind es Flurnamen-Parzellen, keine Aufenthaltsorte.
WOOD_MIN_AREA_M2 = 300_000.0
POI_DEDUP_M = 500.0
# Ein Stadtwald besteht aus vielen Teilflächen, die weit auseinanderliegen —
# mit 500 m zerfiele die Eilenriede in Dutzende Einträge.
DEDUP_M = {"wood": 3000.0}
GEOD = Geod(ellps="WGS84")

STATE_LEVEL = "4"
MUNI_LEVELS = ["8", "6"]  # 8 = Gemeinden, 6 = kreisfreie Städte (Fallback)
NO_STATE = "Deutschland"


def run(cmd):
    print("$ " + " ".join(str(c) for c in cmd), flush=True)
    subprocess.run(cmd, check=True)


def extract(pbf, work):
    """osmium-Pässe; gibt (nodes.geojsonseq, areas.geojsonseq) zurück."""
    raw = work / "places-raw.osm.pbf"
    nodes = work / "place-nodes.geojsonseq"
    areas = work / "areas.geojsonseq"

    if not raw.exists():
        # tags-filter behält per Default die referenzierten Member der Relationen,
        # sonst hätten die Grenz- und Flächen-Polygone keine Geometrie.
        run(["osmium", "tags-filter", str(pbf),
             "n/place=" + ",".join(PLACE_TYPES),
             "nwr/place=square",
             "nwr/highway=pedestrian",
             "nwr/leisure=park,garden",
             "nwr/natural=water,wood",
             "nwr/landuse=forest",
             "n/railway=station",
             "r/admin_level=4,6,8",
             "-o", str(raw), "--overwrite", "--no-progress"])
    else:
        print(f"reuse {raw}", flush=True)

    for out, gtype in ((nodes, "point"), (areas, "polygon")):
        if out.exists():
            print(f"reuse {out}", flush=True)
            continue
        run(["osmium", "export", str(raw), f"--geometry-types={gtype}",
             "-f", "geojsonseq", "-x", "print_record_separator=false",
             "-o", str(out), "--overwrite", "--no-progress"])
    return nodes, areas


def read_seq(path):
    """GeoJSON-Text-Sequence zeilenweise lesen (Datei ist zu groß für json.load)."""
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip().lstrip("\x1e").strip()
            if line:
                yield json.loads(line)


def poi_type(p, is_area=False):
    """OSM-Tags → POI-Typ des Contracts, oder None.

    is_area=True nur beim Polygon-Export. Plätze werden in DE etwa zur Hälfte
    nicht als place=square, sondern als highway=pedestrian + area=yes gemappt
    (z. B. „Am Küchengarten" in Hannover-Linden). Lineare Fußgänger-Ways
    (Georgstraße & Co.) sind Straßen, keine Aufenthaltsorte — die fallen raus,
    weil sie im Polygon-Export gar nicht erst auftauchen.
    """
    if p.get("place") == "square":
        return "square"
    if is_area and p.get("highway") == "pedestrian":
        return "square"
    if p.get("leisure") in ("park", "garden"):
        return "park"
    if p.get("natural") == "water":
        water = p.get("water")
        return "water" if water is None or water in STILL_WATER else None
    if is_area and (p.get("natural") == "wood" or p.get("landuse") == "forest"):
        return "wood"
    if p.get("railway") == "station":
        return "station"
    return None


def load_nodes(path):
    """Punkt-Export → Orts- und POI-Zeilen (name, typ, lat, lng)."""
    places, pois = [], []
    for feat in read_seq(path):
        p = feat.get("properties") or {}
        name = p.get("name")
        if not name:
            continue
        lng, lat = feat["geometry"]["coordinates"][:2]
        lat, lng = round(lat, 4), round(lng, 4)
        if p.get("place") in PLACE_SET:
            places.append((name, p["place"], lat, lng))
        else:
            kind = poi_type(p)
            if kind:
                pois.append((name, kind, lat, lng))
    return places, pois


def load_areas(path):
    """Polygon-Export → Verwaltungsgrenzen (Geometrie) + POI-Zeilen (Punkt)."""
    buckets = {lvl: [] for lvl in [STATE_LEVEL] + MUNI_LEVELS}
    pois = []
    for feat in read_seq(path):
        p = feat.get("properties") or {}
        name = p.get("name")
        level = p.get("admin_level")
        is_admin = p.get("boundary") == "administrative" and level in buckets
        kind = None if is_admin else poi_type(p, is_area=True)
        if not name or (not is_admin and kind is None):
            continue
        try:
            g = shape(feat["geometry"])
        except Exception:
            continue
        if g.is_empty:
            continue
        if is_admin:
            buckets[level].append((name, g))
        else:
            if kind == "wood":
                # Geodätisch messen, NICHT in EPSG:3857 — Web-Mercator-Flächen sind
                # in DE-Breiten um 1/cos²(lat) ≈ 2,6× zu groß, der 30-ha-Schwellwert
                # würde damit auf ~11 ha rutschen und Flurnamen hereinlassen.
                area, _ = GEOD.geometry_area_perimeter(g)
                if abs(area) < WOOD_MIN_AREA_M2:
                    continue
            # representative_point liegt garantiert IN der Fläche (anders als centroid
            # bei U-förmigen Parks) — wichtig für die Gemeinde-Zuordnung.
            try:
                pt = g.representative_point()
            except Exception:
                continue
            pois.append((name, kind, round(pt.y, 4), round(pt.x, 4)))

    admin = {}
    for level, items in buckets.items():
        names = [n for n, _ in items]
        geoms = [g for _, g in items]
        print(f"admin_level={level}: {len(names)} Polygone", flush=True)
        admin[level] = (names, STRtree(geoms) if geoms else None)
    return admin, pois


def dist_m(a, b):
    """Grobe Metrik-Distanz zweier (lat, lng); für eine 500-m-Schwelle genau genug."""
    dlat = (a[0] - b[0]) * 111320.0
    dlng = (a[1] - b[1]) * 111320.0 * math.cos(math.radians((a[0] + b[0]) / 2))
    return math.hypot(dlat, dlng)


def dedup_pois(rows):
    """Multipolygon-Teile und Doppel-Mapping (Way + Relation) zu einem Eintrag
    zusammenfassen: gleicher Name + gleicher Typ + Punkte nah beieinander."""
    kept, groups = [], {}
    for row in rows:
        near = groups.setdefault((row[0], row[1]), [])
        point = (row[2], row[3])
        limit = DEDUP_M.get(row[1], POI_DEDUP_M)
        if any(dist_m(point, seen) < limit for seen in near):
            continue
        near.append(point)
        kept.append(row)
    return kept


def assign(pts, admin, level):
    """Bulk-Point-in-Polygon; gibt Liste[str|None] in Punkt-Reihenfolge zurück."""
    names, tree = admin[level]
    hits = [None] * len(pts)
    if tree is None:
        return hits
    # Prädikat wird als punkt.covered_by(polygon) ausgewertet, nicht umgekehrt.
    for pt_i, geom_i in zip(*tree.query(pts, predicate="covered_by")):
        if hits[pt_i] is None:
            hits[pt_i] = names[geom_i]
    return hits


def main(pbf, out_path):
    pbf = Path(pbf)
    out_path = Path(out_path)

    nodes_seq, areas_seq = extract(pbf, pbf.parent)

    node_places, node_pois = load_nodes(nodes_seq)
    admin, area_pois = load_areas(areas_seq)
    if len(admin[STATE_LEVEL][0]) != 16:
        print(f"WARNUNG: {len(admin[STATE_LEVEL][0])} Bundesländer statt 16", flush=True)

    pois = dedup_pois(node_pois + area_pois)
    print(f"Orts-Nodes: {len(node_places)} | POIs: {len(node_pois)} Nodes + "
          f"{len(area_pois)} Flächen → {len(pois)} nach 500-m-Zusammenfassung", flush=True)
    raw = node_places + pois
    if not raw:
        sys.exit("FEHLER: keine Orte extrahiert — Filter/Input prüfen")

    pts = make_points([r[3] for r in raw], [r[2] for r in raw])
    states = assign(pts, admin, STATE_LEVEL)
    munis = [None] * len(raw)
    for lvl in MUNI_LEVELS:
        munis = [have or new for have, new in zip(munis, assign(pts, admin, lvl))]

    places, seen, no_state = [], set(), 0
    for (name, kind, lat, lng), state, muni in zip(raw, states, munis):
        key = (name, lat, lng)
        if key in seen:
            continue
        seen.add(key)
        if state is None:
            no_state += 1
        rec = {"n": name, "t": kind, "s": state or NO_STATE}
        if kind in PARENT_TYPES and muni and muni != name:
            rec["c"] = muni
        rec["lat"] = lat
        rec["lng"] = lng
        places.append(rec)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({"v": 1, "places": places}, f, ensure_ascii=False, separators=(",", ":"))

    counts = {}
    for r in places:
        counts[r["t"]] = counts.get(r["t"], 0) + 1
    print(f"Duplikate entfernt: {len(raw) - len(places)}")
    print(f"ohne Bundesland (→ '{NO_STATE}'): {no_state}")
    print("Typen: " + " ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    print(f"{out_path}: {len(places)} Einträge, {out_path.stat().st_size / 1e6:.2f} MB")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: build_places.py <germany-latest.osm.pbf> <out places.json>")
    main(sys.argv[1], sys.argv[2])
