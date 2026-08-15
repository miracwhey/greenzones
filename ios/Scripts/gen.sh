#!/usr/bin/env bash
# Projekt aus project.yml erzeugen und die eingecheckten SPM-Pins hineinlegen.
#
# Warum der Umweg: `*.xcodeproj/` ist gitignored (Erzeugnis), damit faellt auch
# das darin liegende Package.resolved aus dem Repo. Die aufgeloeste MapLibre-
# Version ist aber ein Bau-Fakt und gehoert versioniert — sie liegt als
# ios/Package.resolved daneben und wird hier eingespielt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# W2: Orts-Index der Suche bauen, BEVOR xcodegen die Ressourcen einsammelt —
# eine fehlende Datei wuerde sonst still aus dem Projekt fallen und die App
# ohne Ortsverzeichnis ausliefern. Zweiter Lauf ohne Quelländerung tut nichts.
PLACES="$ROOT/GreenZones/Resources/Generated/places.sqlite"
python3 "$ROOT/../pipeline/build_places_sqlite.py"
[ -f "$PLACES" ] || { echo "[gen] FEHLER: $PLACES fehlt"; exit 1; }

/opt/homebrew/bin/xcodegen generate --quiet

PINS_DIR="$ROOT/GreenZones.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$PINS_DIR"
cp "$ROOT/Package.resolved" "$PINS_DIR/Package.resolved"
echo "[gen] GreenZones.xcodeproj erzeugt, Pins aus ios/Package.resolved eingespielt"
