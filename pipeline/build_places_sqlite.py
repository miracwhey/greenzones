#!/usr/bin/env python3
"""
GreenZones-Pipeline: places.json → places.sqlite (FTS5-Ortsindex für die App).

Input:  client/public/places.json  ({"v":1,"places":[{"n","t","s","c"?,"lat","lng"}, …]})
Output: ios/GreenZones/Resources/Generated/places.sqlite  (Schema: places_schema.sql)

Die Datei ist ein Bau-ERZEUGNIS und liegt nicht im Git — `ios/Scripts/gen.sh`
ruft dieses Skript vor xcodegen auf, damit die Ressource beim Projekt-Erzeugen
existiert. Zweiter Lauf ohne Quelländerung tut nichts (`--force` erzwingt).

Warum SQLite statt der JSON: der Web-Client v1 baute den MiniSearch-Index über
164 909 Einträge beim ersten Tastendruck im Worker — Sekunden CPU und ~120 MB
Speicher. FTS5 liest denselben Bestand aus einer read-only Datei im Bundle,
ohne Aufbau.

Nur stdlib: sqlite3, json, unicodedata. Kein Baustein, der nachinstalliert
werden muss.
"""
import argparse
import json
import sqlite3
import sys
import unicodedata
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_SOURCE = REPO / "client/public/places.json"
DEFAULT_TARGET = REPO / "ios/GreenZones/Resources/Generated/places.sqlite"
SCHEMA = Path(__file__).resolve().parent / "places_schema.sql"

# ä→ae ö→oe ü→ue ß→ss — wie client/src/lib/search/normalize.ts.
UMLAUT = str.maketrans({"ä": "ae", "ö": "oe", "ü": "ue", "ß": "ss"})


def normalize(value: str) -> str:
    """Port von `normalize()` aus client/src/lib/search/normalize.ts.

    Reihenfolge ist bindend: erst NFC (damit ein zerlegtes „ü" als ü ankommt und
    zu ue wird, nicht zu u), dann lowercase, dann die Umlaut-Abbildung, erst
    danach die restlichen Diakritika (é→e). Wer NFD vorzieht, bekommt aus
    „Osnabrück" ein „osnabruck" — und findet den Ort nie wieder.
    """
    text = unicodedata.normalize("NFC", value).lower().strip()
    text = text.translate(UMLAUT)
    text = unicodedata.normalize("NFD", text)
    text = "".join(c for c in text if not 0x0300 <= ord(c) <= 0x036F)
    return unicodedata.normalize("NFC", text)


def rows(places):
    """places.json-Einträge → Tabellenzeilen. `id` = Position in der Datei."""
    for index, place in enumerate(places):
        name = place["n"]
        city = place.get("c")
        state = place.get("s") or ""
        # Kontext = Eltern-Gemeinde + Bundesland, wie der `context`-Feldwert des
        # MiniSearch-Dokuments in v1 (places.ts).
        context = " ".join(part for part in (city, state) if part)
        yield (
            index,
            name,
            place["t"],
            state,
            city,
            place["lat"],
            place["lng"],
            normalize(name),
            normalize(context),
        )


def build(source: Path, target: Path) -> None:
    data = json.loads(source.read_text(encoding="utf-8"))
    places = data["places"]
    if not places:
        sys.exit("FEHLER: places.json enthält keine Orte")

    target.parent.mkdir(parents=True, exist_ok=True)
    # Immer frisch bauen: ein Teilbestand aus einem abgebrochenen Lauf wäre ein
    # Index, der still weniger findet.
    tmp = target.with_suffix(".sqlite.tmp")
    tmp.unlink(missing_ok=True)

    db = sqlite3.connect(tmp)
    try:
        db.execute("PRAGMA page_size = 4096")
        db.execute("PRAGMA journal_mode = OFF")
        db.executescript(SCHEMA.read_text(encoding="utf-8"))
        db.executemany(
            "INSERT INTO place(id, name, type, state, city, lat, lng, norm_name, norm_context)"
            " VALUES(?,?,?,?,?,?,?,?,?)",
            rows(places),
        )
        # External-Content-Tabellen füllen sich nicht selbst.
        db.execute("INSERT INTO place_fts(place_fts) VALUES('rebuild')")
        db.execute("INSERT INTO place_tri(place_tri) VALUES('rebuild')")
        db.commit()
        # Nach dem Rebuild liegen die Index-Seiten verstreut; VACUUM schreibt sie
        # zusammenhängend und spart im Bundle zweistellige Prozente.
        db.execute("VACUUM")
        db.commit()
        count = db.execute("SELECT count(*) FROM place").fetchone()[0]
        fts = db.execute("SELECT count(*) FROM place_fts").fetchone()[0]
        tri = db.execute("SELECT count(*) FROM place_tri").fetchone()[0]
    finally:
        db.close()

    if count != len(places) or fts != count or tri != count:
        tmp.unlink(missing_ok=True)
        sys.exit(f"FEHLER: {len(places)} Orte, aber place={count} fts={fts} tri={tri}")

    # Erst umbenennen, wenn der Bestand stimmt — ein halbes places.sqlite im
    # Bundle wäre eine Suche, die stillschweigend weniger kann.
    tmp.replace(target)
    size_mb = target.stat().st_size / 1e6
    print(f"{target}: {count} Orte, {size_mb:.1f} MB")


def main() -> None:
    parser = argparse.ArgumentParser(description="places.json → places.sqlite (FTS5)")
    parser.add_argument("source", nargs="?", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("target", nargs="?", type=Path, default=DEFAULT_TARGET)
    parser.add_argument("--force", action="store_true",
                        help="auch bauen, wenn das Ziel jünger als die Quelle ist")
    args = parser.parse_args()

    if not args.source.exists():
        sys.exit(f"FEHLER: {args.source} fehlt")

    if not args.force and args.target.exists():
        # Das Schema zählt als Quelle: eine geänderte DDL muss neu bauen.
        newest_input = max(args.source.stat().st_mtime, SCHEMA.stat().st_mtime)
        if args.target.stat().st_mtime > newest_input:
            print(f"{args.target}: aktuell, übersprungen")
            return

    build(args.source, args.target)


if __name__ == "__main__":
    main()
