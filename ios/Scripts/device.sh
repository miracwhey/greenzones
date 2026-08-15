#!/usr/bin/env bash
# Release-Build auf Leons iPhone installieren und starten.
#
#   Scripts/device.sh [--no-launch]
#
# Baut die Entwicklungs-Identitaet (`de.leonvalentin.greenzones.dev`, „GZ Dev") —
# die installierte v1-TestFlight-App bleibt damit unangetastet.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEVICE_ID="C6DEA8A4-7771-500E-ABAF-A102AA40F45E"
BUNDLE_ID="de.leonvalentin.greenzones.dev"

echo "[device] Release bauen …"
xcodebuild -project GreenZones.xcodeproj -scheme GreenZones \
    -configuration Release -destination "generic/platform=iOS" \
    -derivedDataPath .dd -clonedSourcePackagesDirPath .spm \
    -allowProvisioningUpdates build

APP="$ROOT/.dd/Build/Products/Release-iphoneos/GreenZones.app"
[ -d "$APP" ] || { echo "[device] FEHLER: $APP fehlt"; exit 1; }

echo "[device] installieren auf $DEVICE_ID …"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"

if [ "${1:-}" != "--no-launch" ]; then
    echo "[device] starten …"
    xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"
fi
