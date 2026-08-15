#!/usr/bin/env bash
# Beweis-Screenshot einer Debug-Route im Simulator.
#
#   Scripts/shot.sh <route> <out.png> [dark]
#   route: map | status_detail | info
#
# Umgebung (optional):
#   GZ_HOUR=12        Stunde fuer das Zeitfenster (Default 12 = time-Zonen aktiv)
#   GZ_SETTLE=9       Sekunden Wartezeit, bis Basemap-Tiles und Sheet stehen
#   GZ_SKIP_BUILD=1   nicht neu bauen/installieren (mehrere Shots hintereinander)
#   GZ_FIXTURES=0     echte Ortung statt Fixture-Punkt (fuer das Onboarding)
#   GZ_FRESH=1        App vorher deinstallieren (leere UserDefaults = Erststart)
#   GZ_ACCURACY=120   Genauigkeit der Fixture-Position in Metern
#
# WICHTIG: Die Env-Variablen gehen als SHELL-PRAEFIX an `simctl launch`.
# Als Argument hinter dem Bundle-Identifier kommen sie still nie an — der
# Prozess startet, liest nichts und der Screenshot zeigt den Default-Zustand.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ROUTE="${1:?Route fehlt: map | status_detail | info}"
OUT="${2:?Zieldatei fehlt}"
APPEARANCE="${3:-light}"

UDID="D8C2B2AC-1A11-423D-AA0F-BBC9D746A0E7"   # iPhone 17 Pro
BUNDLE_ID="de.leonvalentin.greenzones.dev"
HOUR="${GZ_HOUR:-12}"
SETTLE="${GZ_SETTLE:-9}"
FIXTURES="${GZ_FIXTURES:-1}"
ACCURACY="${GZ_ACCURACY:-12}"

echo "[shot] Route=$ROUTE Erscheinung=$APPEARANCE GZ_HOUR=$HOUR → $OUT"

# 1. Simulator hochfahren (idempotent).
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

# 2. Bauen und installieren.
if [ "${GZ_FRESH:-0}" = "1" ]; then
    xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
fi
if [ "${GZ_SKIP_BUILD:-0}" != "1" ] || [ "${GZ_FRESH:-0}" = "1" ]; then
    xcodebuild -project GreenZones.xcodeproj -scheme GreenZones \
        -configuration Debug -destination "platform=iOS Simulator,id=$UDID" \
        -derivedDataPath .dd -clonedSourcePackagesDirPath .spm \
        -allowProvisioningUpdates build >/dev/null
    APP="$ROOT/.dd/Build/Products/Debug-iphonesimulator/GreenZones.app"
    [ -d "$APP" ] || { echo "[shot] FEHLER: $APP fehlt"; exit 1; }
    xcrun simctl install "$UDID" "$APP"
fi

# 3. Erscheinungsbild setzen — vor dem Start, damit die App gleich richtig baut.
xcrun simctl ui "$UDID" appearance "$APPEARANCE"

# 4. Neu starten mit Env als Praefix.
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
SIMCTL_CHILD_GZ_ROUTE="$ROUTE" \
SIMCTL_CHILD_GZ_FIXTURES="$FIXTURES" \
SIMCTL_CHILD_GZ_HOUR="$HOUR" \
SIMCTL_CHILD_GZ_ACCURACY="$ACCURACY" \
    xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null

# 5. Settle: Basemap kommt aus dem Netz, das Sheet oeffnet nach 2,2 s.
sleep "$SETTLE"

mkdir -p "$(dirname "$OUT")"
xcrun simctl io "$UDID" screenshot --type=png "$OUT"
echo "[shot] geschrieben: $OUT"
