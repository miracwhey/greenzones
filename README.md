# GreenZones

iOS-App: Wo Cannabis-Konsum draußen erlaubt ist (§5 KCanG) — Vollbild-Karte, Live-Status, Zeitfenster-Logik. Hobby-Projekt, kein Business.

## Struktur

- `pipeline/` — OSM → Zonen: `./pipeline/run.sh <extract.osm.pbf> <out-dir>` (braucht osmium, tippecanoe, `.venv` mit shapely/pyproj)
- `client/` — Vite + React + TS + Capacitor. Karte: MapLibre GL 4 (v6 rendert nicht headless) + PMTiles
- `client/public/zones.pmtiles` — gebundelte Zonen (aus `data/out*/zones.pmtiles`)
- `mockup/`, `app/` — abgenommenes HTML-Mockup + Web-PoC (Referenz)
- `data/` — Geofabrik-Extrakte + Pipeline-Output (nicht einchecken)

## Kommandos

```bash
# Web-Dev
cd client && npm run dev

# Screenshots (Sichtprüfung)
npm run build && npm run preview -- --port 4173 &
node shot.mjs "http://localhost:4173/?lat=52.3728&lng=9.7386&hour=12" out.png onboarded

# iOS
npx cap sync ios
xcodebuild -project ios/App/App.xcodeproj -scheme App -sdk iphonesimulator build CODE_SIGNING_ALLOWED=NO
```

Debug-Query-Params: `?lat=&lng=` (Standort-Override), `?hour=` (Zeitfenster-Test).

## Zonenlogik (§5 Abs. 2 KCanG)

- **ban** (rot): 100 m-Buffer um Schulen, Kitas, Spielplätze, öffentl. Sportstätten — ganztägig. Gebuffert wird die ganze OSM-Fläche, nicht nur der Eingangsbereich → bewusst großzügiger als das Gesetz.
- **time** (orange): Fußgängerzonen, verboten 7–20 Uhr. Linien-Geometrien als ~8 m-Korridor.

Disclaimer in App: Orientierungshilfe, keine Rechtsberatung, OSM-Vollständigkeit nicht garantiert.

## Datenquelle

Zonendaten abgeleitet aus [OpenStreetMap](https://www.openstreetmap.org) — © OpenStreetMap-Mitwirkende, lizenziert unter der [Open Database License (ODbL) 1.0](https://opendatacommons.org/licenses/odbl/). Das gilt auch für die gebundelte `client/public/zones.pmtiles`.
