#!/usr/bin/env bash
# Beweis-Screenshot einer Debug-Route im Simulator.
#
#   Scripts/shot.sh <route> <out.png> [dark]
#   route: map | status_detail | info
#          W2: search | search_results | search_offline | target | target_detail
#          W3: map_spots | newspot | pick | detail | solo | invite | sent
#              | manage | reply | friends | profile | profile_empty | welcome
#
# Umgebung (optional):
#   GZ_HOUR=12        Stunde fuer das Zeitfenster (Default 12 = time-Zonen aktiv)
#   GZ_SETTLE=9       Sekunden Wartezeit, bis Basemap-Tiles und Sheet stehen
#   GZ_SKIP_BUILD=1   nicht neu bauen/installieren (mehrere Shots hintereinander)
#   GZ_FIXTURES=0     echte Ortung statt Fixture-Punkt (fuer das Onboarding)
#   GZ_FRESH=1        App vorher deinstallieren (leere UserDefaults = Erststart)
#   GZ_ONBOARDING_STEP=2  Onboarding faengt bei Schritt 2 an (0..3, nur fuer Bilder)
#   GZ_INFO_OPEN=manage   Info-Blatt startet im Unterblatt „Karte & Daten"
#   GZ_SHARE_OPEN=access|manage  Spot-Blatt startet im Zugangs- bzw.
#                         Verwalten-Unterblatt (der Schalter steckt seit dem
#                         18.08. in SpotDetailSheet, kam hier aber nie an)
#   GZ_HINTS_RESET=1      In-Kontext-Hinweise wieder auf ungesehen
#   GZ_SCAN_RESULT=<text> Scanner-Route: dieser Inhalt gilt als erkannt
#                         (Einladung → Accept-Weg, anderes → „Kein GreenZones-Code")
#   GZ_ACCURACY=120   Genauigkeit der Fixture-Position in Metern
#   GZ_AT=48.14,11.58 Fixture-Standort woandershin verlegen (Abdeckung pruefen)
#
# WICHTIG: Die Env-Variablen gehen als SHELL-PRAEFIX an `simctl launch`.
# Als Argument hinter dem Bundle-Identifier kommen sie still nie an — der
# Prozess startet, liest nichts und der Screenshot zeigt den Default-Zustand.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ROUTE="${1:?Route fehlt — siehe Kopf dieser Datei}"
OUT="${2:?Zieldatei fehlt}"
APPEARANCE="${3:-light}"

# W2: ueberschreibbar per GZ_SIM_UDID. Zwei Builder auf EINEM Simulator mit
# derselben Bundle-ID ueberschreiben sich gegenseitig die installierte App —
# der Shot zeigt dann die Welle des anderen. Default bleibt iPhone 17 Pro.
UDID="${GZ_SIM_UDID:-D8C2B2AC-1A11-423D-AA0F-BBC9D746A0E7}"   # iPhone 17 Pro
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
SIMCTL_CHILD_GZ_ONBOARDING_STEP="${GZ_ONBOARDING_STEP:-0}" \
SIMCTL_CHILD_GZ_INFO_OPEN="${GZ_INFO_OPEN:-}" \
SIMCTL_CHILD_GZ_SHARE_OPEN="${GZ_SHARE_OPEN:-}" \
SIMCTL_CHILD_GZ_HINTS_RESET="${GZ_HINTS_RESET:-}" \
SIMCTL_CHILD_GZ_AT="${GZ_AT:-}" \
SIMCTL_CHILD_GZ_SCAN_RESULT="${GZ_SCAN_RESULT:-}" \
    xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null

# 5. Settle: Basemap kommt aus dem Netz, das Sheet oeffnet nach 2,2 s.
sleep "$SETTLE"

mkdir -p "$(dirname "$OUT")"
xcrun simctl io "$UDID" screenshot --type=png "$OUT"
echo "[shot] geschrieben: $OUT"
