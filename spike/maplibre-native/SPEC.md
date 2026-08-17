# Karten-Spike — MapLibre Native iOS + zones.pmtiles

Schritt 1 des gelockten SwiftUI-Neubaus (15.08.2026). Ziel: **messen, nicht glauben**,
ob MapLibre Native iOS die bestehende `zones.pmtiles` direkt rendert — inkl.
Zonen-Styling und Zeitfenster-Zustand wie im Web-Client v1.

## Faktenlage (recherchiert 15.08.2026)

- MapLibre iOS unterstützt PMTiles ab **6.10.0** offiziell: `pmtiles://<absolute-file-url>`
  als `configurationURL` einer `MLNVectorTileSource`, auch aus dem App-Bundle
  (Quelle: `platform/ios/MapLibre.docc/PMTiles.md`). Kein Offline-Pack/Caching für
  PMTiles-Sources — für uns egal, Datei liegt im Bundle.
- Fallback, falls Messung scheitert: `mbtiles://` (tippecanoe liegt unter
  `/opt/homebrew/bin/tippecanoe`) oder GeoJSON-Source. **Fallback erst nach
  berichteter Fehl-Messung, nicht präventiv bauen.**

## Festgenagelt

- **Ort:** `spike/maplibre-native/` im greenzones-Repo. Wegwerf-Spike, aber sauber.
- **Projekt:** xcodegen (`project.yml`), App `GreenZonesSpike`, SwiftUI-Lifecycle,
  iOS Deployment Target 17.0, Bundle-ID `com.greenzones.spike`,
  `DEVELOPMENT_TEAM: KXJRXU59ZB`, automatic signing (Sim braucht keins).
- **SPM:** `https://github.com/maplibre/maplibre-gl-native-distribution`, `from: 6.10.0`.
- **Daten:** `zones.pmtiles` NICHT kopieren — xcodegen-Resource-Referenz auf
  `../../client/public/zones.pmtiles` (eine Quelle, 61,7 MB Bundle ok für Spike).
- **UI:** `ContentView` = Vollbild-Karte (`ignoresSafeArea`), `UIViewRepresentable`
  um `MLNMapView`. Basemap wie v1: hell `https://tiles.openfreemap.org/styles/positron`,
  dunkel `https://tiles.openfreemap.org/styles/dark` (nach `colorScheme`).
- **Source/Layer** in `mapView(_:didFinishLoading:)` — exakt v1-Werte
  (`client/src/components/MapView.tsx:103-139` ist die Referenz):
  - Source `zones`: `MLNVectorTileSource`, `pmtiles://` + Bundle-URL.
  - `ban-fill`: Fill, sourceLayer `ban`, `#E5484D`, Opacity dark 0.22 / light 0.16.
  - `ban-line`: Line, `ban`, `#E5484D`, Breite 1.6, Opacity 0.75.
  - `time-fill`: Fill, `time`, `#F76B15`, Opacity `timeActive ? (0.22/0.16) : 0.07`.
  - `time-line`: Line, `time`, `#F76B15`, Breite 1.6, Dash `[2.2, 1.6]`
    (`lineDashPattern`), Opacity `timeActive ? 0.85 : 0.4`.
- **Zeitfenster** (Port von `client/src/lib/time.ts`): `banAtHour(h) = h >= 7 && h < 20`.
  Stunden-Override per Env `GZ_HOUR` (`ProcessInfo`) — Pendant zu `?hour=` in v1,
  für den Beweis beider Zustände.
- **Kamera:** Center `lng 9.7386, lat 52.3728` (Hannover, v1-FALLBACK_CENTER),
  Zoom 14.2.
- **Diagnose:** Delegate-Fehlerpfade (`mapViewDidFailLoadingMap` etc.) loggen mit
  Präfix `[GZSpike]`.

## Beweis-Gates (Messung = Deliverable)

1. Build grün via `xcodebuild` gegen iOS-Simulator — NUR xcodebuild zählt, keine
   SourceKit-/LSP-Urteile.
2. Sim-Lauf mit Screenshots nach Karten-Settle (`xcrun simctl io booted screenshot`),
   abgelegt als `spike/maplibre-native/shots/`:
   - `sim_day.png` (`SIMCTL_CHILD_GZ_HOUR=12`): ban-Zonen rot, time-Zonen kräftig orange.
   - `sim_night.png` (`SIMCTL_CHILD_GZ_HOUR=22`): time-Zonen blass (0.07/0.4), ban bleibt.
3. Screenshots ANSEHEN: Zonen-Geometrie sichtbar über Basemap? Leerer Layer bei
   grünem Build = Messergebnis „PMTiles nein", nicht überspielen — dann berichten,
   NICHT eigenmächtig Fallback bauen.
4. Geräte-Beweis (Leons iPhone via devicectl) folgt nach Sim-Abnahme — nicht Teil
   des Builder-Auftrags.
