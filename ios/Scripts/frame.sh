#!/usr/bin/env bash
# EIN Bild einer laufenden Bewegung, zu einem bekannten Zeitpunkt.
#
#   Scripts/frame.sh <route> <t_ms> <out.png> [dark]
#
#   route  wie bei shot.sh — sie stellt die Ausgangslage und loest den Uebergang aus
#   t_ms   Zeitpunkt in REALER Bewegungszeit, gemessen ab dem Ausloesen
#   out    Zieldatei
#
# Umgebung:
#   GZ_SLOWMO=10      Dehnfaktor der Federn (Default 10). Ein Screenshot trifft
#                     keine 120-ms-Marke; bei Faktor 10 wird daraus 1,2 s.
#                     `t_ms` bleibt trotzdem die REALE Zeit — das Skript rechnet.
#   GZ_UI_SETTLE=8    Sekunden, die die Karte vor dem Uebergang stehen darf
#   GZ_SKIP_BUILD=1   nicht neu bauen (Serie von Frames)
#   GZ_HOUR / GZ_FIXTURES / GZ_ACCURACY / GZ_SIM_UDID — wie shot.sh
#
# WARUM EIN BILD PRO LAUF: mehrere Screenshots in einem Durchlauf kosten je
# 300–600 ms, und jeder spaetere Zeitpunkt waere um die Summe der frueheren
# verschoben. Eine Serie entsteht durch mehrere Laeufe mit GZ_SKIP_BUILD=1.
#
# WAS DIE ZEITLUPE BEWEIST: die Form der Bewegung — wo das Objekt zu welchem
# Bruchteil steht, ob es ueberschwingt, ob Grund und Chrome versetzt kommen.
# Eine Feder mit `response × N` ist dieselbe Kurve, nur gestreckt.
# WAS SIE NICHT BEWEIST: die absolute Dauer. Die steht in `DesignTokens.swift`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ROUTE="${1:?Route fehlt — siehe Kopf von shot.sh}"
T_MS="${2:?Zeitpunkt in ms fehlt}"
OUT="${3:?Zieldatei fehlt}"
APPEARANCE="${4:-light}"

UDID="${GZ_SIM_UDID:-D8C2B2AC-1A11-423D-AA0F-BBC9D746A0E7}"   # iPhone 17 Pro
BUNDLE_ID="de.leonvalentin.greenzones.dev"
SLOWMO="${GZ_SLOWMO:-10}"
SETTLE="${GZ_UI_SETTLE:-8}"
HOUR="${GZ_HOUR:-12}"
FIXTURES="${GZ_FIXTURES:-1}"
ACCURACY="${GZ_ACCURACY:-12}"

# Wartezeit nach der Startmarke: reale Zeit × Dehnfaktor.
WAIT_S=$(python3 -c "print(f'{$T_MS/1000*$SLOWMO:.3f}')")
echo "[frame] Route=$ROUTE t=${T_MS} ms real → ${WAIT_S}s bei Zeitlupe ×$SLOWMO → $OUT"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

if [ "${GZ_SKIP_BUILD:-0}" != "1" ]; then
    xcodebuild -project GreenZones.xcodeproj -scheme GreenZones \
        -configuration Debug -destination "platform=iOS Simulator,id=$UDID" \
        -derivedDataPath .dd -clonedSourcePackagesDirPath .spm \
        -allowProvisioningUpdates build >/dev/null
    APP="$ROOT/.dd/Build/Products/Debug-iphonesimulator/GreenZones.app"
    [ -d "$APP" ] || { echo "[frame] FEHLER: $APP fehlt"; exit 1; }
    xcrun simctl install "$UDID" "$APP"
fi

xcrun simctl ui "$UDID" appearance "$APPEARANCE"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true

# Der Log-Strom muss VOR dem Start laufen, sonst faellt die Marke hinein, bevor
# jemand zuhoert.
#
# Das Praedikat filtert auf den PROZESS, nicht auf den Text der Marke: `log
# stream` druckt sein Praedikat als erste Zeile aus („Filtering the log data
# using …"). Stuende die Marke darin, faende der grep unten sie sofort — das
# Skript haette dann ab Startzeit gezaehlt statt ab der Ausloesung und jeden
# Frame Sekunden zu frueh geschossen. Genau so ist der erste Lauf gescheitert.
MARK="$(mktemp -t gzmotion)"
xcrun simctl spawn "$UDID" log stream --style compact \
    --predicate 'processImagePath CONTAINS "GreenZones"' > "$MARK" 2>/dev/null &
LOG_PID=$!
trap 'kill "$LOG_PID" 2>/dev/null || true; rm -f "$MARK"' EXIT
sleep 1.2

SIMCTL_CHILD_GZ_ROUTE="$ROUTE" \
SIMCTL_CHILD_GZ_FIXTURES="$FIXTURES" \
SIMCTL_CHILD_GZ_HOUR="$HOUR" \
SIMCTL_CHILD_GZ_ACCURACY="$ACCURACY" \
SIMCTL_CHILD_GZ_SLOWMO="$SLOWMO" \
SIMCTL_CHILD_GZ_UI_SETTLE="$SETTLE" \
    xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null

# Auf die Startmarke warten. Die Aufloesung des Pollings (20 ms) ist bei
# Zeitlupe ×10 ein realer Fehler von 2 ms.
DEADLINE=$(python3 -c "import time; print(time.time() + $SETTLE + 25)")
while ! grep -q "GZ-MOTION" "$MARK" 2>/dev/null; do
    python3 -c "import time,sys; sys.exit(0 if time.time() < $DEADLINE else 1)" \
        || { echo "[frame] FEHLER: keine Startmarke — laeuft die Route ueberhaupt?"; exit 1; }
    sleep 0.02
done
SEEN_AT="$(python3 -c "import time; print(f'{time.time():.3f}')")"

# Wie alt war die Marke, als das Skript sie sah? Das ist die Genauigkeit des
# Werkzeugs, und sie gehoert in jeden Lauf: `log stream` liefert nicht sofort,
# und ein unbemerkter Versatz von zwei Sekunden verschiebt JEDEN Frame um
# dieselben zwei Sekunden — sichtbar nur daran, dass die Bewegung nie im Bild
# ist. Der Versatz wird abgezogen, damit `t_ms` wirklich ab der Ausloesung zaehlt.
LAG=$(python3 - "$MARK" "$SEEN_AT" <<'PY'
import re, sys, time, datetime
path, seen = sys.argv[1], float(sys.argv[2])
line = next(l for l in open(path) if "GZ-MOTION" in l)
stamp = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)", line).group(1)
logged = datetime.datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S.%f").timestamp()
print(f"{max(0.0, seen - logged):.3f}")
PY
)
REST=$(python3 -c "print(f'{max(0.0, $WAIT_S - $LAG):.3f}')")
echo "[frame] Marke gesehen mit ${LAG}s Verzug → noch ${REST}s warten"
if python3 -c "import sys; sys.exit(0 if $LAG > $WAIT_S else 1)"; then
    echo "[frame] WARNUNG: der Verzug ist groesser als der Zeitpunkt — dieser Frame liegt HINTER t=${T_MS} ms."
fi
WAIT_S="$REST"

python3 -c "import time; time.sleep($WAIT_S)"
mkdir -p "$(dirname "$OUT")"
xcrun simctl io "$UDID" screenshot --type=png "$OUT"

# Die Marke sagt, womit die App wirklich gelaufen ist. Ohne diese Zeile waere
# ein Frame ohne sichtbare Bewegung nicht von einer nicht angekommenen
# Zeitlupe zu unterscheiden.
grep -m1 "GZ-MOTION" "$MARK" | sed 's/^/[frame] Marke: /'
echo "[frame] geschrieben: $OUT"
