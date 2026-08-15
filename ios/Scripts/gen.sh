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

/opt/homebrew/bin/xcodegen generate --quiet

PINS_DIR="$ROOT/GreenZones.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$PINS_DIR"
cp "$ROOT/Package.resolved" "$PINS_DIR/Package.resolved"
echo "[gen] GreenZones.xcodeproj erzeugt, Pins aus ios/Package.resolved eingespielt"
