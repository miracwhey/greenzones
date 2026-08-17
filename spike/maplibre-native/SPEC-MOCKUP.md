# Snap-UX-Mockup — SwiftUI auf der Spike-Karte (bindend)

Schritt 2 des Neubaus. Klickbares Anfass-Mockup auf Leons iPhone: Fixture-Daten,
KEIN CloudKit, KEINE echte Kamera. Ziel: Leon beurteilt „intuitiv und clean" mit
echten Gesten am Gerät. Design-Gate danach — dieses Dokument ist die bindende Spec.

## Gelockte Produktentscheide (Stand 15.08. spät — Leon-Korrektur eingearbeitet)

1. **Album/Spot-Gedächtnis:** Snaps bleiben dauerhaft, neuester zuerst.
   Löschen nur Autor + Host. Kein Verfall.
2. **Snappen geht ÜBERALL (Leon-Korrektur, ersetzt den Vor-Ort-Zwang):**
   globaler Plus-Button → Kamera. Der Aufnahme-Ort entscheidet automatisch:
   - in Spot-Nähe (Mockup-Schwelle 30 m) → Snap landet im Spot (Strip + Stack),
   - sonst → Snap wird **eigener Pin an der Aufnahme-Position** auf der Karte.
   Nur Live-Kamera bleibt (kein Mediathek-Import). Nähe-Check rein lokal.
3. **Karten-Look Snaps (Leon-Wort „gestapelte, kleine, runde Preview-Bilder"):**
   runde Foto-Thumbnails, bei mehreren gestapelt/überlappend — kein Eck-Badge,
   kein Zähler-Dot-Design.
   **Iteration 15.08. (Leon: Mechanik gut, „die überlappenden Fotos dominieren
   zu sehr"):** Pin-Look wird leiser, 3 Varianten per `GZ_PIN_STYLE={a,b,c}`:
   - **A** Emoji-Anker: Spot-Pin = 40-pt-Emoji-Glass-Kreis (wie leer); Snaps als
     2 gefächerte 22-pt-Foto-Kreise oben rechts dahinter, bei >2 zusätzlich
     „+n"-Mini-Chip (Glass, `.caption2`). Kein Emoji-Chip nötig — Emoji IST der Pin.
   - **B** Ein-Foto: Spot-Pin = einzelner 30-pt-Foto-Kreis (neuester Snap),
     Emoji-Chip 18 pt unten links. Kein Fächer; Menge erst im Sheet.
   - **C** Zoom-adaptiv: heutiger 3er-Stack, aber Thumbnails 26 pt (statt 36),
     Versatz ~9 pt; unter Zoom 13,5 kollabiert der Pin zum 40-pt-Emoji-Kreis mit
     16-pt-Foto-Dot oben rechts (neuester Snap); Übergang animiert (spring),
     Hysterese ±0,2 Zoom gegen Flackern an der Schwelle.
   - Freie Snap-Pins in ALLEN Varianten: 32 pt (statt 40), Ring 1,5 px; bei C
     unter Zoom 13,5 auf 22 pt geschrumpft.
4. UGC-Pflichten sichtbar im Mockup: Melden (Snap), Blockieren/Entfernen (Teilnehmer).
5. Wording konsumneutral (Store-Fassade): nur „Spot", „Snap", „Freunde" — nie
   Konsum-Vokabular.
6. Sichtbarkeits-Vorschlag (im Gate zu bestätigen, im Mockup so gezeigt):
   freier Snap → alle Freunde; Spot-Snap → Spot-Teilnehmer.

## Design-Sprache (aus v1 `client/src/theme.css` — exakt übernehmen)

- Farben: ok `#1DB954` · ban `#E5484D` · time `#F76B15` · accent `#0A84FF` ·
  ink `#17191C`/dark `#F2F3F5` · ink-2 `#5A616B`/`#A7ADB7` · app-bg `#E8EAED`/`#131518`.
- Glass: SwiftUI `.ultraThinMaterial` + 1-px-Stroke (weiß 8 % dark / ink 8 % light),
  Corner-Radius-Sprache 14–20, durchgehend Continuous Corners.
- Typo: System (SF Pro), Titel `.headline`, Meta `.caption` in ink-2.
- Motion: `.spring(response: 0.4, dampingFraction: 0.85)` überall; Haptik
  `UIImpactFeedbackGenerator(.medium)` bei Auslöser und Long-Press.
- Dark + Light beide sauber (colorScheme), Zonen-Layer der Karte bleiben AN.

## Fixture-Daten (statisch, in `Sources/Fixtures.swift`)

- User-Position (blauer Puck-Punkt, statisch): `52.3595, 9.7400` (nahe Maschsee-Nordufer).
- Spot A „Unsere Bank" 🌳 `52.3592, 9.7412` — Distanz ~40 m → NAH. Teilnehmer:
  Leon (ich), Tara, Robert (Initial-Avatare, Farben deterministisch aus Namen).
  4 Snaps: (snap1, Tara, vor 2 Std) · (snap2, Leon, vor 5 Std) ·
  (snap3, Robert, gestern) · (snap4, Tara, vor 3 Tagen).
- Spot B „Küchengarten-Ecke" ☀️ `52.3712, 9.7135` — ~2 km → FERN. Teilnehmer
  Leon, Tara. 0 Snaps (Empty-State).
- **2 freie Snap-Pins** (ohne Spot): snap3 (Tara, vor 1 Std) `52.3641, 9.7448` ·
  snap4 (Robert, gestern) `52.3555, 9.7365` — zeigen den Frei-Pin-Look auf der Karte.
- Foto-Dateien: `Sources/Fixtures/snap1.jpg … snap4.jpg` (3:4 Hochformat).
  **Fehlen sie beim Build: mit `Scripts/make_placeholders.sh` (schreibst du:
  `sips`/CoreGraphics-CLI erzeugt 4 unterschiedliche Duotone-Gradients 900×1200
  in ok/time/accent/ink-Tönen) generieren und einbinden — gleiche Dateinamen,
  echte Fotos werden später ohne Codeänderung eingetauscht.**

## Screens & Zustände

### 1. Karte (bestehende MapContainer erweitern)
- Annotationen müssen mit der Karte MITSCHWENKEN, framegenau, kein Nachzieh-Lag.
- **Spot-Pin ohne Snaps:** 44-pt-Kreis, Glass-Fill, 2-px-Ring (ok-grün wenn nah,
  ink-3 wenn fern), Emoji zentriert.
- **Spot-Pin mit Snaps = Foto-Stack:** bis zu 3 runde Snap-Thumbnails (36 pt,
  2-px-weißer Ring, weiche Schatten `shadow-1`), überlappend gefächert
  (Versatz ~12 pt horizontal, neuester VORNE/oben), plus kleiner Emoji-Chip
  (20 pt, Glass) unten links am Stack als Spot-Identität. Kein Zähler-Dot,
  kein Eck-Badge — der Stack selbst kommuniziert „mehrere".
- **Freier Snap-Pin:** einzelnes rundes Foto-Thumbnail 40 pt, 2-px-weißer Ring,
  kleiner Spitz/Stiel nach unten auf den Ankerpunkt (damit es als Pin liest,
  nicht als schwebender Avatar). Tap → Viewer direkt (Kontext „Snap von Tara").
- **Plus-FAB** unten rechts (v1-FAB-Position, über der Karte, Glass, accent-Plus,
  56 pt): Tap → Kamera von überall.
- Tap auf Spot-Pin → Spot-Sheet.

### 2. Spot-Sheet (`.sheet`, Detents `.medium` + `.large`, Grabber sichtbar)
- Header: Emoji (32 pt) · Name `.headline` · darunter Meta „3 Freunde · 40 m".
- Legal-Status-Zeile wie v1-StatusBar-Ästhetik: Dot (ok-grün) + „Hier erlaubt" +
  sekundär „Fußgängerzone 480 m" (statische Fixture-Werte).
- **Snap-Strip** (horizontale ScrollView, 12-pt-Spacing, Kacheln 84×112, Radius 14):
  - Kachel 1 = **Snap-CTA**: accent-Fill, weißes Kamera-Symbol, Label „Snap" —
    IMMER aktiv (Nähe-Zwang ist gekippt; aus dem Sheet = expliziter Spot-Snap).
    Tap → Kamera mit Spot-Kontext.
  - Dann Snaps neuester zuerst: Foto füllt Kachel, unten Gradient-Scrim mit
    „Tara · vor 2 Std" `.caption2`. Tap → Viewer an diesem Index.
  - Empty-State (Spot B): nur CTA-Kachel + daneben Hint in ink-2:
    „Noch keine Snaps — sei die/der Erste."
- Teilnehmer-Zeile: Avatar-Kreise + Namen; **Long-Press auf Teilnehmer ≠ ich →
  Context-Menü „Blockieren" (rot) / „Aus Spot entfernen" (nur weil ich Host bin)**
  — Aktion = Toast „Im Mockup ohne Funktion".
- Footer: „Einladen"-CTA (Glass-Pill) — no-op, nur fürs Gesamtbild.

### 3. Kamera (fullScreenCover, Hintergrund `#0B0C0E`)
- „Sucher" = snap2.jpg vollflächig, ganz leicht abgedunkelt (Mockup-Stellvertreter
  für Live-Preview; KEIN AVFoundation).
- Oben: X (links) · **Kontext-Chip** zentriert (Glass-Pill), automatisch nach
  Aufnahme-Ort: in Spot-Nähe „🌳 Unsere Bank", sonst „📍 Neuer Snap hier".
  Aus dem Spot-Sheet geöffnet: immer der Spot-Chip (expliziter Spot-Snap).
- Unten: Auslöser 76-pt-Ring (weiß, 5 pt Stroke, innerer Kreis), links Blitz-,
  rechts Flip-Ghost-Button (nur Optik).
- Auslöser: Haptik + kurzer Weiß-Blitz → Cover schließt, Ergebnis nach Kontext:
  - Spot-Kontext → neuer Snap animiert als erste Strip-Kachel + Stack am Pin
    wächst (spring).
  - Frei-Kontext → **neuer runder Snap-Pin ploppt an der User-Position auf**
    (Scale-in mit spring). Der Moment muss sitzen — Kern-Belohnung des Features.
- **Fixture-Demo beider Pfade:** User-Distanz zu Spot A ist 40 m, Schwelle 30 m —
  Plus-FAB erzeugt also einen FREIEN Snap-Pin; der Spot-Pfad wird über die
  CTA-Kachel im Spot-Sheet erlebt (aus dem Sheet = explizit an diesen Spot).

### 4. Viewer (fullScreenCover, schwarz)
- `TabView(.page)` horizontal ab getipptem Index, Foto aspect-fit.
- Oben Glass-Bar: „Tara · vor 2 Std" + X. Drag-nach-unten schließt (interactive,
  Foto folgt dem Finger, Opacity-Fade).
- **Long-Press → Context-Menü: „Melden…" · „Löschen" (destruktiv, nur bei
  Autor == ich).** „Melden…" → Confirmation-Dialog „Snap melden? Er wird für dich
  ausgeblendet und dem Spot-Host gemeldet." → blendet den Snap im Mockup real aus.

## Technisch

- Alles im bestehenden Spike-Target (`spike/maplibre-native/`), neue Dateien:
  `Fixtures.swift`, `SpotPinsOverlay.swift`, `SpotSheet.swift`, `SnapCamera.swift`,
  `SnapViewer.swift`; `ContentView` verdrahtet. `project.yml`: Fixtures-Ordner als
  Resources. GZ_HOUR-Mechanik und Zonen-Layer unangetastet.
- State: ein `@Observable MockStore` (Spots, Snaps, hidden-IDs, addSnap()).
- Kein CloudKit, kein Netz außer Basemap, keine Permissions-Dialoge.

## Beweis-Gates

1. Release-Build grün via xcodebuild (Simulator-Destination reicht dir; Gerät
   übernimmt Fable).
2. Sim-Screenshots nach Settle,
   `shots/mock_{map,sheet_near,sheet_far,camera,viewer,report,freesnap}.png`
   (`mock_freesnap` = Karte NACH Plus-FAB-Aufnahme: neuer freier Pin sichtbar)
   — alle SELBST ansehen: Foto-Stack an Pin A als gestapelte Kreise erkennbar?
   Freie Snap-Pins rund mit Stiel? Scrim-Text lesbar? Dark ODER Light konsistent
   (ein Modus reicht für die Shots, Code muss beide können).
3. Interaktions-Pfade, die Screenshots nicht beweisen (Auslöser-Animation,
   Drag-Dismiss, Context-Menüs), im Report als GERÄTE-TEST OFFEN deklarieren —
   nicht als bewiesen melden.
