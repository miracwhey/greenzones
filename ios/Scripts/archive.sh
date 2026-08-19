#!/usr/bin/env bash
# Store-Archiv bauen und optional nach TestFlight hochladen.
#
#   Scripts/archive.sh            # nur archivieren
#   Scripts/archive.sh --upload   # archivieren UND hochladen
#
# ⚠️ Konfiguration ist `Distribution`, NICHT `Release`. Release traegt die
# Entwicklungs-Identitaet `de.leonvalentin.greenzones.dev` („GZ Dev"), damit die
# installierte TestFlight-App beim Geraete-Test unangetastet bleibt. Ein
# Release-Archiv laesst sich bauen und signieren — der Upload scheitert dann erst
# ganz am Ende mit „Error Downloading App Information", weil es zu dieser
# Bundle-ID keine App im Store gibt.
#
# Der Upload laeuft im `-exportArchive`-Schritt mit; „EXPORT SUCCEEDED" plus
# „Uploaded App" heisst: der Build liegt bei Apple und geht ins Processing.
#
# Signiert wird mit dem ASC-Team-Key (nicht dem APNs- und nicht dem IAP-Key,
# die geben auf der ASC-API 401).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

KEY_ID="84T69B383M"
ISSUER_ID="87de864d-0331-4ad9-9dfe-cd752f709a29"
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
ARCHIVE="$ROOT/.dd/GreenZones.xcarchive"

[ -f "$KEY_PATH" ] || { echo "[archive] FEHLER: $KEY_PATH fehlt"; exit 1; }

AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$KEY_PATH"
      -authenticationKeyID "$KEY_ID"
      -authenticationKeyIssuerID "$ISSUER_ID")

echo "[archive] archivieren …"
rm -rf "$ARCHIVE"
xcodebuild -project GreenZones.xcodeproj -scheme GreenZones \
    -configuration Distribution -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    -derivedDataPath .dd -clonedSourcePackagesDirPath .spm \
    "${AUTH[@]}" archive

PLIST="$ARCHIVE/Products/Applications/GreenZones.app/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")
echo "[archive] fertig: $VERSION ($BUILD)"

if [ "${1:-}" != "--upload" ]; then
    echo "[archive] kein Upload (--upload uebergeben, wenn er laufen soll)"
    exit 0
fi

echo "[archive] exportieren und hochladen …"
rm -rf "$ROOT/.dd/export"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$ROOT/ExportOptions.plist" \
    -exportPath "$ROOT/.dd/export" \
    "${AUTH[@]}"
echo "[archive] hochgeladen: $VERSION ($BUILD)"
