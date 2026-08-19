# GreenZones — SwiftUI-Neubau: Architektur-SPEC

Stand: 2026-08-15 · Autor: Fable (Design + Verify) · Builder: Opus · Status: **Entwurf, wartet auf Leons Go**

Diese SPEC ist bindend für alle Builder-Aufträge des Neubaus. Sie ersetzt keine Produktentscheide — die stehen in
`docs/konzept-community-local-first.md` (Produkt-Verfassung, inkl. Snap-Gate 15.08.) und werden hier nur referenziert.
Der technische Bestand ist in `docs/cloudkit-contract.md` (v1-Contract) beschrieben; Abschnitt 7 definiert dessen v2-Delta.

---

## 0. Zielbild und Nicht-Ziele

**Ziel:** Eine native SwiftUI-App, die den Web/Capacitor-Client v1 (`client/`) vollständig ersetzt — gleiche App im Store,
gleiche Nutzerdaten, gleiche Freunde — und die Snap-Funktion (Phase 2 des Community-Konzepts) mitbringt.

Feature-Parität v1, die der Neubau haben MUSS:
Vollbild-Karte mit Zonen (ban/time, Zeitfenster-Farben) · Standort-Puck · Legal-Status-Bar unten + Detail-Sheet + Zonenliste ·
Info-Sheet · Onboarding (Standort-Erlaubnis) · Suche (Orte offline + Adressen online, Recents) · Ziel-Modus ·
Spots (lokal + geteilt) · Einladungen mit Zeit-Band + „jeder sagt seine Zeit" · Freunde per Link · Profil (Name + Emoji) ·
Sichtbare Pushes mit Notification-Service-Extension.

Neu: Snaps (Kamera, Spot-Album, freie Snap-Pins, Freunde-Feed, Sichtbarkeits-Schalter, Melden/Blockieren/Löschen).

**Nicht-Ziele:** Kein Server, keine Accounts, keine Telemetrie (Produktregel). Kein Android. Kein Konsum-Tracking (Phase 3).
Kein Mediathek-Import. Kein Personen-Picker pro Snap (v1 der Snaps). Keine Live-Position teilen.

---

## 1. Entscheidungen (mit Begründung)

| # | Entscheidung | Warum |
|---|---|---|
| E1 | **Bundle-ID `de.leonvalentin.greenzones` und Container `iCloud.de.leonvalentin.greenzones` bleiben.** NSE-Bundle-ID `de.leonvalentin.greenzones.NotificationService`. Team `KXJRXU59ZB`. | Gleicher App-Store-Record (6798829082), TestFlight-Track läuft weiter (Build-Nummer > 3), alle CloudKit-Daten von Leon/Robert bleiben gültig. Ein neuer Container würde alle Freundschaften/Spots wegwerfen. |
| E2 | **Deployment-Target iOS 17.0.** | Spike läuft auf 17; `@Observable`, `presentationBackground`, MapLibre 6.x. v1 war 15.0 — Testgeräte (15 Pro Max, iPhone 16) sind weit drüber. |
| E3 | **Lokale Persistenz = SQLite via GRDB** (SPM `groue/GRDB.swift`), eine App-DB `greenzones.sqlite` in Application Support + eine **gebündelte, read-only `places.sqlite`** (FTS5) für die Suche. | Leon-Lock „Suche = SQLite FTS5". Damit ist SQLite eh im Haus; eine Persistenz-Story für alles (Spots, Snaps-Metadaten, Outbox, Caches). GRDB liefert Migrationen + `ValueObservation` für SwiftUI. Kein SwiftData: dessen CloudKit-Pfad kann kein CKShare-Sharing, wir syncen ohnehin selbst. |
| E4 | **CloudKit-Sync = 1:1-Port des bewährten `CloudKitService` (Vollabzug pro Zone, Zone-Sharing, 1 Record = 1 Schreiber). Kein CKSyncEngine.** | 920 Zeilen geräteerprobter Code inkl. der teuren Erkenntnisse (Kaltstart-Accept, `__defaultOwner__`, Offer-Idempotenz). Datenmengen bleiben winzig; Assets (Snaps) werden über `desiredKeys` vom Vollabzug ausgenommen und lazy geladen (Abschnitt 12). CKSyncEngine wäre ein Neuschreiben mit neuem Risiko ohne Nutzen. |
| E5 | **Freunde-Feed = eigene Zone `feed-<uuid>` pro Person, zone-wide CKShare, alle Freunde Teilnehmer.** Verteilung über den bestehenden Offer-Mechanismus (`FeedOffer` in der Friendship-Zone, Auto-Accept), nicht über Teilnehmer-Lookup. | Nutzt exakt das SpotOffer-Muster (bewiesen), braucht keine `CKUserIdentity`-Lookups (kein Nutzerverzeichnis — Produktregel). 1 Foto = 1 Upload, egal wie viele Freunde. |
| E6 | **Legal-Status-Engine liest `zones.pmtiles` selbst** (eigener PMTiles-Reader + MVT-Decoder in Swift), unabhängig vom Karten-Renderer. | v1-Architektur, bewusst: Status am Ziel-Punkt außerhalb des Viewports, Zoom-unabhängig, offline. **Eine Zonen-Quelle** (Leon: „eine Quelle"). Testvektoren aus v1 sichern Parität. |
| E7 | **Geteiltes Swift-Package `GreenZonesKit`** (Modelle, Schema-Konstanten, CloudKit-Zugriff, Engine, Suche, Stores) — genutzt von App, NSE und Tests. | Beseitigt die heutige Duplikation zwischen App und Extension; testbar ohne UI. |
| E8 | **Pin-Look Variante A hart** (Leon-Wahl 15.08.), B/C-Code wird nicht portiert. Tap auf Pin fährt die Karte. | Design-Gate geschlossen. |
| E9 | **Kein App-Store-Assets-Refresh in dieser SPEC** — Icon/Splash von v1 werden übernommen. | Nicht Teil des Neubau-Ziels. |

➜ *Simpel (Zusammenfassung für Leon):* Gleiche App-Identität wie heute (nichts geht verloren) · eine kleine Datenbank im Gerät statt vieler JSON-Schnipsel · der bewährte iCloud-Sync wird abgeschrieben, nicht neu erfunden · Fotos bekommen einen eigenen „Freunde-Behälter" pro Person.

---

## 2. Repo-Layout und Targets

```
ios/                                  ← NEU (Neubau); client/ bleibt bis zum Ship als v1-Referenz stehen
  project.yml                         xcodegen; Package.resolved WIRD eingecheckt
  GreenZones/                         App-Target (SwiftUI)
    App/            GreenZonesApp.swift, AppDelegate/SceneDelegate-Adaptoren (Push, Share-Accept), AppModel (Composition Root)
    Features/       Map/, Status/, Search/, Target/, Spots/, Invites/, Friends/, Profile/, Snaps/, Info/, Onboarding/
    Design/         DesignTokens.swift (GZ.*), GlassCard, Haptics
    Resources/      Assets.xcassets (Icon/Splash von v1), Info.plist, GreenZones.entitlements
  NotificationService/                NSE-Target (Port aus client/ios/App/NotificationService)
  Packages/GreenZonesKit/             lokales SPM-Package (Sources/GreenZonesKit, Tests/GreenZonesKitTests)
    Sources/GreenZonesKit/
      Model/        Spot, Friend, Invitation, Reply, Snap, Profile, LegalStatus, Place, …
      Time/         GZTime (injizierbare Clock)
      Geo/          Distanz, Point-in-Polygon, Polygon-Kanten-Distanz
      Zones/        PMTilesReader, MVTDecoder, ZoneEngine
      Search/       PlacesIndex (FTS5), PhotonClient, SearchController, Merge, Normalize, Recents
      Store/        AppDatabase (GRDB, Migrationen), SpotStore, InviteStore, FriendStore, SnapStore, Outbox
      Cloud/        CKSchema, CloudKitService, SyncCoordinator (mergeSnapshot), ShareAccept, Subscriptions
      Snaps/        SnapCapturePipeline (Resize/JPEG/Thumb), SnapAssetCache
  Tests/GreenZonesUITestsLite/        (optional später) — Screenshots laufen über DEBUG-Routen, siehe 14
  Scripts/                            shot.sh (Sim-Screenshots per GZ_ROUTE), device.sh (devicectl install/launch)
pipeline/build_places_sqlite.py       NEU: places.json → places.sqlite (FTS5), siehe 10
```

Bundle-Ressourcen (Referenz, nicht Kopie — wie im Spike): `../client/public/zones.pmtiles` (61,7 MB) und die von der Pipeline
erzeugte `pipeline/out/places.sqlite`. Beide sind Build-Inputs; `zones.pmtiles` liegt bereits im Git.

Info.plist (App): `CFBundleDisplayName GreenZones` · `CFBundleDevelopmentRegion de` · `CADisableMinimumFrameDurationOnPhone true` ·
`CKSharingSupported true` · `UIBackgroundModes [remote-notification]` · `NSLocationWhenInUseUsageDescription` (Text aus v1) ·
`NSCameraUsageDescription` (neu, konsumneutral: „Für Snaps an deinen Spots und auf der Karte.") · Portrait-only ·
`ITSAppUsesNonExemptEncryption false` · `UILaunchScreen` · `UIApplicationSceneManifest` mit eigenem `SceneDelegate`.
Entitlements: iCloud-Container + CloudKit-Service wie v1; **`aps-environment` = `production`** im Release-Export (v1 hatte `development` — bekannte Lücke). NSE-Entitlements wie v1 (iCloud, kein aps).

Signing: Automatic, Team `KXJRXU59ZB`. Versionen: `MARKETING_VERSION 2.0`, `CURRENT_PROJECT_VERSION` beginnt bei **4** (v1-Build 3 ist der letzte).

**Nur iPhone: `TARGETED_DEVICE_FAMILY "1"` — und zwar in `settings.base` JEDES Targets, nicht auf Projekt-Ebene.**
xcodegen schreibt jedem Target seinen Default `"1,2"`, und Target-Settings schlagen Projekt-Settings; ein Wert oben
sieht richtig aus und wirkt nicht. Build 4 ging deshalb als iPad-App zu Apple und wurde bei der Einreichung mit
`STATE_ERROR.SCREENSHOT_REQUIRED.APP_IPAD_PRO_3GEN_129` abgewiesen — kein Feld in App Store Connect zeigt das vorher an.
Geprüft wird nie an `project.yml`, sondern an der Autorität, je Target:
`xcodebuild -target <T> -configuration Distribution -showBuildSettings | grep TARGETED_DEVICE_FAMILY`.

**Konfigurationen (xcodegen `configs`):** `Debug`, `Release` und `Distribution`. Debug/Release = Entwicklungs-Builds mit
`PRODUCT_BUNDLE_IDENTIFIER de.leonvalentin.greenzones.dev` (NSE `…​.dev.NotificationService`) und `CFBundleDisplayName GZ Dev` —
damit ein Geräte-Build während W1–W5 die installierte v1-TestFlight-App auf Leons iPhone NICHT ersetzt. `Distribution` = Store-Identität
aus E1 (`de.leonvalentin.greenzones`, „GreenZones"), nur für Archive/TestFlight (W6). Der iCloud-Container ist in allen Konfigurationen derselbe;
`com.apple.developer.icloud-container-environment` steht in Dev-Builds auf `Development` (eigene Testdaten), in `Distribution` auf `Production`.
Sprachmodus `SWIFT_VERSION 5.0` (Swift-6-Compiler, Strict-Concurrency `targeted`) — kein Swift-6-Modus im Port.

---

## 3. Architektur-Schichten

```
SwiftUI-Views (Features/*)  ──beobachten──▶  @Observable Stores (Kit/Store)  ──lesen/schreiben──▶  GRDB (AppDatabase)
        │                                            ▲
        │ Aktionen                                   │ mergeSnapshot / Outbox
        ▼                                            │
   AppModel (Composition Root)  ──▶  SyncCoordinator ──▶ CloudKitService ──▶ CloudKit (private/shared DB)
        │
        ├─▶ LocationService (CLLocationManager) ─▶ ZoneEngine.status(at:) ─▶ LegalStatus (Bar, Sheets, Ziel-Modus, Snap-Kontext)
        ├─▶ SearchController (FTS5 + Photon)
        └─▶ MapContainer (UIViewRepresentable, MLNMapView) — Pins/Puck/Zonen-Layer/Kamera-Fahrten
```

Regeln:
- **Ein Wahrheitsspeicher pro Datenart**: Stores lesen aus GRDB, Cloud-Ergebnisse gehen über `mergeSnapshot` (pure Funktion, portiert aus `client/src/lib/spots/sync.ts`) in GRDB, nie direkt in Views.
- **Ehrlichkeitsregel v1 bleibt:** Einladung/Antwort/Profil gehen ZUERST in die Cloud, dann lokal; Fehler sichtbar (Toast mit `cloudMessage`). Outbox nur für: Spot-Share-Anlage (`sharePending`, wie v1) und **Snap-Uploads** (neu, weil Fotos offline aufgenommen werden können — Produktregel „Offline als Normalzustand").
- Zeit kommt aus einer injizierbaren `Clock` (Tests + Debug-Override), nicht aus `ProcessInfo`.
- Logging über `OSLog` (Subsystem `de.leonvalentin.greenzones`, Kategorien `cloud`, `map`, `search`, `snaps`), keine `NSLog`.

---

## 4. Lokales Datenmodell (GRDB, `greenzones.sqlite`)

Tabellen (Migration `v1`):

| Tabelle | Spalten (Kern) | Herkunft |
|---|---|---|
| `spot` | id TEXT PK, name, emoji, lng, lat, createdAt, zoneName?, ownerId?, shareURL?, sharePending INT | v1 `Spot` |
| `spot_participant` | spotId, userId | v1 `participantIds` |
| `friend` | id TEXT PK (userRecordID), name, emoji?, color, friendshipZone, feedZone?, blocked INT | v1 `Friend` + neu `feedZone`, `blocked` |
| `invitation` | id PK, spotId, hostId, time, createdAt, cancelled INT | v1 |
| `reply` | invitationId, participantId, status ('in'/'out'), arrivalTime? — PK (invitationId, participantId) | v1 |
| `snap` | id TEXT PK, authorId, createdAt, lat, lng, spotId?, spotZone?, spotName?, spotEmoji?, scope ('feed'/'spot'), zoneName, recordName, thumbPath?, photoPath?, uploadState ('pending'/'uploading'/'done'/'failed'), hidden INT | neu |
| `recent_search` | key PK, name, lat, lng, detail?, at | v1 Recents |
| `setting` | key PK, value | displayName, emoji, profileAsked, onboarded, notificationAsked, … |

Migration von v1-Daten beim ersten Start: `UserDefaults` mit Präfix `CapacitorStorage.` (`gz_spots`, `gz_invites`, `gz_friends`,
`gz_display_name`, `gz_profile_emoji`, `gz_profile_asked`) einmalig einlesen → GRDB, danach Marker `setting.migratedV1 = 1`.
Rein lokale Spots (ohne `zoneName`) sind sonst weg. Recents/Onboarding dürfen verfallen. Test mit v1-Fixture-JSON aus `client/shot_spots.mjs`.

Bilder liegen NICHT in der DB: `Application Support/snaps/<id>.jpg` (Original, max. 1600 px lange Kante, JPEG q0.82) und
`Caches/snaps/thumb/<id>.jpg` (320 px). Fremde Snaps: nur Thumb + on-demand Original in `Caches/`.

---

## 5. Karte (`Features/Map`, aus dem Spike)

Übernommen aus `spike/maplibre-native/Sources/MapContainer.swift` + `SpotPinsOverlay.swift` (Muster + Geometrie), mit diesen Pflicht-Fixes:
1. **`dark`/`timeActive` dynamisch:** Style-URL-Wechsel bei `colorScheme`-Änderung (`mapView.styleURL = …`, Layer in `didFinishLoading` erneut anlegen), Layer-Opacity bei Stundenwechsel per Timer (30 s, wie v1) nachziehen — der Spike friert beides ein.
2. **Spots diffbar** wie freie Pins (`syncSpotPins`: add/remove/move), nicht Einmal-Installation.
3. **Puck = echte Position** (`CLLocationManager`, `desiredAccuracy = kCLLocationAccuracyBest`, `distanceFilter = 5`), Genauigkeits-Ring wie v1, Follow-Modus bricht bei Drag; FAB „Auf Standort zentrieren".
4. **Kamera-Fahrten:** Pin-Tap → `focus(coordinate, bottomInset: höhe*0.5)` (Spike, 0,45 s ease-in-out); Ziel-Modus → `flyTo` Zoom 15 mit Offset [0,-60] (v1); Suchtreffer → dito.
5. `preferredFramesPerSecond = .maximum`, PMTiles-Init via `configurationURLString:` (Header-Regel), `zoneSource` strong, Fit hängt am Style-Callback, `didSelect` → sofort deselect — alles wie Spike.
6. Zonen-Layer exakt v1: `ban-fill #E5484D` (0.16/0.22 dark) · `ban-line` 1.6/0.75 · `time-fill #F76B15` (`timeActive ? 0.16|0.22 : 0.07`) · `time-line` 1.6, dash [2.2,1.6], `timeActive ? 0.85 : 0.4`. Basemap OpenFreeMap positron/dark.
7. Pins: `SpotPinView` **nur Variante A** (40-pt-Emoji-Glass, 2×22-pt-Fotos hinten bei (58,20)/(68,27), „+n"-Chip 24×15 bei (46,44); Ring `ok` bei ≤75 m sonst `ink3`), `FreeSnapPinView` 32 pt mit Stiel (`centerOffset`/`anchorPoint`-Trick), `PuckView`, Pop-in-Animation für neue freie Pins, Stack-Grow bei neuem Spot-Snap. Ziel-Pin (v1) als eigene Annotation.
8. Attribution/Logo: bleiben sichtbar (MapLibre-Pflicht), über der Status-Bar (Gerät prüfen — v1-Altlast).

---

## 6. Legal-Status-Engine (`Kit/Zones`) — Port von `client/src/lib/zones.ts`

- `ZoneEngine(pmtilesURL:)` → `func status(at: CLLocationCoordinate2D) async -> ZoneStatus` mit
  `struct LayerStatus { inside: Bool; nearestM: Double }` (`0` wenn inside, `.infinity` wenn > 2000 m) und `struct ZoneStatus { ban, time }`.
- 3×3-Tile-Fenster auf **z14** um den Punkt, LRU 32 Tiles, Layer `ban`/`time`, Ray-Casting mit Löchern, Kanten-Distanz equirektangular (`client/src/lib/geo.ts`).
- Eigener **PMTilesReader** (v3-Header, Root-/Leaf-Directories, gzip-Inflate via `Compression` mit Gzip-Header-Strip) und **MVTDecoder** (Protobuf-Varint-Parser für `layer/feature/geometry`, Kommandos MoveTo/LineTo/ClosePath, Ring-Orientierung → Polygon/Löcher). Keine externe Protobuf-Abhängigkeit.
- Verdikt: `StatusKind = ok | ban | time | wait` exakt wie `StatusBar.statusKind()`; `spotAllowedAt(status, at:)` wie `timeFmt.ts`. Zeitfenster `7 ≤ h < 20`.
- Neuberechnung: Standort ≥ 15 m bewegt oder Ziel gewechselt; Zeit-Tick 30 s.
- **Testvektoren:** Skript `client/scripts/export_zone_vectors.mjs` (neu, Node, nutzt `zones.ts` unverändert) erzeugt `ios/Packages/GreenZonesKit/Tests/Fixtures/zone_vectors.json`: 300 Punkte (Raster über Hannover-Innenstadt + 40 Handpunkte an Zonenrändern + Maschsee + Küchengarten). Swift-Test vergleicht `inside` exakt und `nearestM` mit ±1,5 m (Infinity exakt). Das ist der Paritätsbeweis der Engine.

---

## 7. CloudKit-Contract v2 (Delta zu `docs/cloudkit-contract.md`)

Unverändert: Container, Zone-Sharing (`CKShare(recordZoneID:)`, `publicPermission .readWrite`), Friendship-Zone (`Friendship`, `Profile`, `SpotOffer`), Spot-Zone (`Spot`, `Invitation`, `Reply`), 1 Record = 1 Schreiber, Vollabzug ohne Tokens, Subscriptions `gz-private-db-v2`/`gz-shared-db-v2`, Kaltstart-Accept über `connectionOptions.cloudKitShareMetadata`, Offer-Idempotenz.

**Neu:**

| Wo | Record-Type · recordName | Felder | Schreiber |
|---|---|---|---|
| Friendship-Zone | `FeedOffer` · `feedoffer-<userRecordID>` | `feedShareURL: String` | jede Person für den eigenen Feed |
| **Feed-Zone `feed-<uuid>`** (private DB des Autors, zone-wide Share, Teilnehmer = alle Freunde) | `Feed` · `feed` | `createdAt` | Owner, einmalig |
| Feed-Zone | `Snap` · `<uuid>` (lokale Snap-ID) | `createdAt: Date`, `lat`, `lng`, `thumb: CKAsset`, `photo: CKAsset`, `spotZone: String?`, `spotName: String?`, `spotEmoji: String?` | Autor = Owner |
| Feed-Zone | `Report` · `report-<snapId>-<userRecordID>` | `snapId`, `createdAt` | der Meldende |
| Spot-Zone | `Snap` · `<uuid>` | wie oben (ohne spot*-Felder — die Zone IST der Spot) | Autor (jeder Teilnehmer) |
| Spot-Zone | `Report` · `report-<snapId>-<userRecordID>` | `snapId`, `createdAt` | der Meldende |

- **Feed-Anlage:** beim ersten Start mit Account (`ensureFeedZone`, idempotent wie `createSpotShare`); Share-URL lokal merken. Bei jeder Freundschaft (neu oder bestehend ohne `FeedOffer` von mir) schreibt jede Seite ihren `FeedOffer` in die Friendship-Zone. `acceptPendingOffers` behandelt `FeedOffer` wie `SpotOffer` (Zone bekannt? sonst accept). Bestehende v1-Freundschaften bekommen den Feed damit automatisch nach dem Update.
- **Sichtbarkeit (Leon-Lock):** Snap „Alle Freunde" → Feed-Zone (mit `spotZone/spotName/spotEmoji`, wenn am Spot aufgenommen). Snap „Nur Freunde im Spot" → Spot-Zone. **Album eines Spots = Spot-Zone-Snaps ∪ Feed-Snaps aller Teilnehmer mit passendem `spotZone`.** Freunde ohne Spot-Zugang sehen Feed-Snaps mit `spotName` als Foto-Pin „bei 🌳 Spotname".
- **Vollabzug + Assets:** `recordZoneChanges` mit `desiredKeys` OHNE `thumb`/`photo` für `Snap`. Thumbs werden nach dem Merge für alle sichtbaren, ungecachten Snaps per `CKFetchRecordsOperation(desiredKeys: ["thumb"])` geladen (Batch ≤ 20), Original erst beim Öffnen im Viewer. Cache-Pfade siehe 4.
- **Löschen:** Autor löscht seinen Record; Spot-Owner darf Snaps in seiner Spot-Zone löschen (Zone-Owner-Recht). Feed-Snaps eines Fremden am eigenen Spot kann der Host NICHT löschen (fremde Zone) — er kann sie **melden** (= für sich ausblenden + `Report`). Konsequenz aus dem Lock, im Konzept vermerken.
- **Melden:** lokal `hidden = 1` + `Report`-Record in der Zone des Snaps. Der Autor sieht Reports auf eigene Snaps (Badge im eigenen Album, Zähler) — kein Auto-Löschen. Reicht für Apple 1.2 im privaten Kreis.
- **Blockieren / Freund entfernen (v1-Lücke, jetzt Pflicht):** `removeFriend(userId)`: (a) als Owner der Friendship-Zone: Zone löschen; als Teilnehmer: `CKShare` verlassen (Teilnehmer-Record entfernen / `CKAcceptShares`-Gegenstück = `sharedCloudDatabase.delete(withRecordZoneID:)`); (b) Person aus allen eigenen Spot-Shares und aus dem eigenen Feed-Share entfernen (`share.removeParticipant`); (c) lokal `friend.blocked = 1`, deren Snaps/Spots ausblenden. Zwei Netz-Phasen, jede für sich idempotent; UI meldet Teilerfolg ehrlich.
- **NSE-Ereignisse erweitern:** Rangfolge `Invitation > SpotOffer > Snap > Reply > Profile`; Snap-Text „🌳 Maschsee-Bank: Tara hat einen Snap gemacht" bzw. „Tara hat einen Snap gemacht". `FeedOffer`/`Feed`/`Report` erzeugen nie ein Banner.
- Contract-Doc `docs/cloudkit-contract.md` wird vom Builder der Welle 4 um genau diese Punkte ergänzt (Abschnitt „v2 — Neubau"), Konzept-Doc-Widersprüche (CKQuerySubscription, Child-Records) dort korrigiert.

---

## 8. Suche (`Kit/Search`) — Port von `client/src/lib/search/`

**Index-Bau (Pipeline, offline):** `pipeline/build_places_sqlite.py` liest `client/public/places.json` (v1, 164 909 Einträge, Felder `n,t,s,c,lat,lng`) und schreibt `places.sqlite`:
```sql
CREATE TABLE place(id INTEGER PRIMARY KEY, name TEXT, type TEXT, state TEXT, city TEXT, lat REAL, lng REAL, norm_name TEXT, norm_context TEXT);
CREATE VIRTUAL TABLE place_fts USING fts5(norm_name, norm_context, content='place', content_rowid='id', tokenize='unicode61 remove_diacritics 2', prefix='2 3 4');
CREATE VIRTUAL TABLE place_tri USING fts5(norm_name, content='place', content_rowid='id', tokenize='trigram');   -- Tippfehler-Fallback
```
`norm_*` = v1-`normalize()` (lowercase, ä→ae ö→oe ü→ue ß→ss, Diakritika weg) — dieselbe Funktion in Swift für die Query. `VACUUM`, page_size 4096, read-only im Bundle (Kopie nach Caches ist NICHT nötig; GRDB öffnet read-only aus dem Bundle).

**Query-Pfad (Swift, Hintergrund-Queue):**
1. Terme normalisieren; jeder Term als Prefix (`term*`), **AND** über `place_fts`; leer → **OR**; immer noch leer und Query ≥ 3 Zeichen → `place_tri` (Trigram-Substring) als Tippfehler-Fallback (ersetzt MiniSearch `fuzzy 0.2` — dokumentierte Abweichung).
2. Ranking: `score = -bm25(place_fts, 3.0, 0.2) × typeWeight × proximityBoost` mit v1-Werten (`TYPE_WEIGHT`: city 3 · town 2.5 · station 2.2 · village 2 · square 1.9 · suburb/quarter/neighbourhood/park 1.8 · water/wood 1.7 · hamlet 1.2 · sonst 1.5; `proximityBoost = 1 + 0.6/(1 + km/30)`). Kandidaten `LIMIT 60` vor der Nachgewichtung, Ausgabe `OFFLINE_LIMIT 6`.
3. `PhotonClient` (URLSession, `https://photon.komoot.io/api/?limit=5&lang=de&bbox=5.8,47.2,15.1,55.1&q=…`, Timeout 5 s, Debounce 300 ms, `MIN_QUERY_ONLINE 3`), Outcome `ok|offline|timeout|server` — nie werfen.
4. `dedupeAgainstOffline` (gleicher normalisierter Name UND < 150 m), Sektionen „Zuletzt gesucht" / „Orte" / „Adressen & Straßen", Recents max 5 (GRDB `recent_search`).
5. `SearchController` als `@Observable` State-Machine mit denselben Zuständen wie v1 (`SearchState`, `OnlineState`, `IndexState`) — jede Störung sichtbar.

**Tests:** Die 98 v1-Suchtests (`client/src/lib/search/__tests__/`) sind die Verhaltensspezifikation: Fixture (17 Places inkl. „Großen Linden", „Stadtteilpark Linden-Süd") wird als Mini-`places.sqlite` im Test gebaut; portiert werden `places` (19), `merge` (6), `normalize` (4), `recents` (9), `photon`-Mapping (12), Controller-Sequenzen (Kern der 34: Sequenz-Guards, AND→OR, Offline/Timeout-States). Golden-Queries gegen die echte `places.sqlite`: „Küchengarten", „Von-Alten-Garten", „Maschsee", „hannover hbf", „linden" — Top-1 muss der erwartete Ort sein (Liste in der Testdatei, aus v1 abgeleitet).

---

## 9. UI-Screens und Referenzen

Design-Tokens 1:1 aus dem Spike (`GZ.*`, dynamische UIColor, `theme.css`-Werte), Radii 14–20 continuous,
**drei Federn nach Masse** (`GZ.sheetSpring` 0.52/0.90 · `GZ.elementSpring` 0.36/0.82 · `GZ.microSpring` 0.22/0.80,
Werte aus `mockup/motion-v6.html`; die frühere Einheitsfeder `GZ.spring` gibt es nicht mehr),
Glas = `.regularMaterial` für Sheets, `.ultraThinMaterial` für Chips/FAB, System-Font. Beide Themes Pflicht.

**Morph (Design/SnapMorph.swift).** Wo ein Bild schon sichtbar ist, geht das Vollbild daraus HERVOR statt aufzublenden
(Album-Kachel und freier Snap-Pin tragen das Foto bereits). Ein Element macht den ganzen Weg (`SnapFlier`), Quelle und
Ziel rechnet dieselbe Funktion: cover → contain ist ein Ausschnittwechsel, das Ziel ist die contain-Fläche des Bildes in
`SPScreen.contentBounds` — nie der volle Schirm, sonst springt es im Übergabe-Frame. Herkunft steht im Register
(`CommunityModel.noteSnapRect` / `MapPinRectSink`), nicht im Aufruf: die Karte kann ihre Pin-Lage nur auf Nachfrage
liefern, und sie ändert sich zwischen Hin- und Rückweg. Wisch-Dismiss geht ohne Rückmorph (die Geste hat das Bild
bereits bewegt). Der frisch aufgenommene Snap laeuft denselben Weg rueckwaerts: vom Sucher (formatfuellend über
`SPScreen.bounds`) an seinen Pin, dessen Lage aus der Koordinate gerechnet wird — beim Start des Fluges existiert er
noch nicht. Der Pin bleibt unsichtbar, solange sein Bild unterwegs ist, und ploppt erst bei der Ankunft; nach einem Flug
ohne Sprung aus dem Nichts, weil das Foto schon in voller Groesse dasteht.
Wording konsumneutral (nur „Spot", „Snap", „Freunde"; Store-Fassade), Legal-Texte aus v1 (`StatusBar.tsx`, `ZoneList.tsx`, `InfoSheet.tsx`) wörtlich.

| Screen | Referenz (bindend) | Hinweise |
|---|---|---|
| Karte + FABs | v1 `App.tsx` (4 FABs: Spot markieren · Freunde · Zentrieren · Info) + Spike Plus-FAB | Neubau: **Plus-FAB (Snap) unten rechts wie Spike**, die 4 v1-FABs als vertikale Gruppe darüber. Ausblenden im Pick-Modus. |
| Status-Bar unten + Detail-Sheet | v1 `StatusBar.tsx`, `ZoneList.tsx`, Mockup `mockup/redesign_b.html`, Shots `client/bar_{idle,idle_dark,detail,target}.png` | 58 pt Bar (Dot + Titel + Distanzen + Chevron), Tap → Sheet (Status-Header, Zonenliste, Foot). Haptik bei Statuswechsel. Ziel-Modus-Bar mit X. |
| Suche | v1 `SearchBar.tsx`, Shots `client/ui_*.png` | Overlay-State, Auswahl auf Touch-Down, Sektionen + alle Störungs-States sichtbar. |
| Ziel-Modus | v1 `MapView.tsx` (Ziel-Pin, flyTo) + StatusBar-Target | „Am Ziel erlaubt/verboten", Sheet „Am Ziel". |
| Info-Sheet, Onboarding | v1 `InfoSheet.tsx`, `Onboarding.tsx` | Texte wörtlich; ODbL-Attribution (Commit `8a9a97e`) übernehmen. |
| Spots: NewSpot / Detail / Invite / Reply / Manage / Friends / Profile | v1 `SpotSheets.tsx`, `TimeTape.tsx`, Mockups `mockup/community.html`, `mockup/invite.html`, `mockup/profile.html`, Shots `client/sp_shots/`, `mockup/iv_*.png`, `mockup/pf_*.png` | TimeTape-Mechanik exakt (48 pt/Std, 36 h, absolute Viertelstunden, „Jetzt"-Rastzone < 8 min, Anker, Referenz-Flagge; 12 Tests portieren). „Jeder sagt seine Zeit" (v2.2). Profil A+B (Zeile im Freunde-Sheet + Schritt nach Beitritt). Sackgassen-Regel: ohne Freunde immer „Freund einladen"-CTA. |
| Spot-Sheet mit Snap-Album | Spike `SpotSheet.swift` (Layout, Detents `.medium/.large`, Legal-Zeile, Snap-Strip 84×112, CTA immer aktiv, Teilnehmer-Menüs) | Wird mit dem v1-Spot-Detail (Einladung/RSVP) **zu einem Sheet** zusammengeführt: Header · Legal-Zeile · Snap-Strip · Einladung/„Wer kommt" · Teilnehmer · Aktionen. Fable liefert dafür vor Welle 5 ein Layout-Mockup (HTML) zur Abnahme. |
| Kamera | Spike `SnapCamera.swift` (Chrome) + `AVCaptureSession` (Rückkamera, Foto, Blitz-Toggle, Wechsel-Button aktiv) | Kontext-Chip automatisch nach Aufnahme-Ort (30 m), Sichtbarkeits-Schalter „Alle Freunde / Nur Freunde im Spot" nur im Spot-Kontext, Default „Alle Freunde". Auslöser 76-pt-Ring, Flash-Timing, Haptik wie Spike. |
| Viewer | Spike `SnapViewer.swift` komplett | `.alert` für Melden (iOS-26-Befund), Löschen nur Autor/Host, Drag-Dismiss. |
| Snap-Pins | Spike Variante A + freie Pins | Tap → Karte fährt + Sheet/Viewer. |

Kern-Moment (SPEC-MOCKUP): freier Snap → Pin ploppt an der Aufnahme-Position auf (Spring). Muss sitzen.

---

## 10. Snaps — Ablauf

1. Plus-FAB → Kamera-Cover. `captureContext()` = nächster Spot ≤ 30 m (echte Distanz), sonst frei. Sichtbarkeit Default „Alle Freunde".
2. Auslöser → `SnapCapturePipeline`: Original → 1600 px JPEG q0.82 + Thumb 320 px, EXIF-Orientierung eingebrannt, **GPS-EXIF entfernt** (Position steht im Record, nicht im Bild). Lokal in DB (`uploadState pending`) + Dateien. UI reagiert sofort (Pin/Stack), Upload asynchron über Outbox (Retry bei Netz/Resume, Fehler sichtbar im Album als „wartet auf Upload").
3. Upload: `Snap`-Record mit `CKAsset(fileURL:)` in Feed- oder Spot-Zone; ohne Feed-Zone (kein Account) bleibt der Snap lokal (Feed-lose Snaps sind erlaubt: local-first) und der Album-Hinweis erklärt es.
4. Fremde Snaps: Merge → Thumb-Fetch → Pins/Album; Original beim Öffnen.
5. Löschen/Melden/Blockieren wie 7.

---

## 11. Push / NSE

Port `client/ios/App/NotificationService/NotificationService.swift` in das NSE-Target, Konstanten und `fetchAllRecords` aus `GreenZonesKit` (kein Duplikat mehr). App: `@UIApplicationDelegateAdaptor` für `registerForRemoteNotifications`, `didReceiveRemoteNotification` → `SyncCoordinator.refresh()`; `SceneDelegate` (über `UISceneConfiguration`) für **beide** Share-Accept-Wege (Kaltstart + laufend). `ensureNotificationPermission` zustandsbasiert am Freundes-Bestand (v1-Regel).

---

## 12. Tests und Beweis-Gates

- Runner: **Swift Testing** (`Testing`-Framework, Xcode 26). Package-Tests laufen mit `xcodebuild test -scheme GreenZonesKit -destination 'platform=iOS Simulator,name=iPhone 16 Pro'`.
- Pflicht-Suiten: `ZoneEngineVectorTests` (300 Vektoren) · `SearchTests` (Port + Golden) · `TimeTests` · `MergeSnapshotTests` (Port der 24 aus `sync.test.ts`) · `StoreTests` (Kern der 31: Persistenz, Upsert je participantId, Idempotenz) · `TimeTapeMathTests` (Snap-Regeln aus `timeTape.test.tsx`) · `V1MigrationTests` · `SnapPipelineTests` (Größe, EXIF-GPS weg, Orientierung) · `CKSchemaTests` (recordName-Ableitungen).
- **Screenshot-Routen (nur `#if DEBUG`):** Launch-Env `GZ_ROUTE={map,status_detail,search,target,spot_sheet,newspot,invite,reply,friends,profile,camera,viewer,report,freesnap}` + `GZ_FIXTURES=1` (Fixture-Store statt DB, Fixture-Position Hannover, Fixture-Fotos = die 4 Duotone-JPEGs aus dem Spike, keine Fremdfotos) + `GZ_HOUR`. `ios/Scripts/shot.sh <route> <out.png> [dark]` fährt Sim (Env als **Präfix** vor `simctl launch`, nie als Argument), wartet auf Settle, schießt.
- **Jede Welle endet mit:** `xcodebuild build` Release grün (nur xcodebuild zählt) · alle Tests grün · Pflicht-Shots hell+dunkel von Fable angesehen · Geräte-Build via `ios/Scripts/device.sh` auf Leons iPhone (Release!) · Interaktionen, die Shots nicht beweisen, im Report als **GERÄTE-TEST OFFEN** deklariert.

---

## 13. Bau-Wellen (Opus-Builder; Fable = SPEC-Ergänzung, Review, Bild-Verify, Geräte-Lauf)

| Welle | Inhalt | Liest zuerst | Gate |
|---|---|---|---|
| **W1 Gerüst + Karte + Status** | `ios/` xcodegen (App, NSE-Stub, Kit, Tests), Entitlements/Plist, DesignTokens, GZTime/Clock, Modelle, MapContainer + Pins (A) + Puck + Location, Zonen-Layer dynamisch, ZoneEngine + PMTiles/MVT + Vektor-Test, Status-Bar + Detail-Sheet + ZoneList + Info + Onboarding, Debug-Routen `map/status_detail`, `shot.sh`/`device.sh` | diese SPEC 2–6, 9, 12; Spike-Sources; `client/src/lib/{zones,geo,time}.ts`; `StatusBar.tsx`, `ZoneList.tsx`, `InfoSheet.tsx`, `Onboarding.tsx`; `mockup/redesign_b.html`; `client/bar_*.png` | Vektor-Test grün · Shots idle/idle_dark/detail · Gerät: Karte + Status live an Leons Standort |
| **W2 Suche + Ziel-Modus** | `build_places_sqlite.py`, PlacesIndex/Photon/Merge/Recents/Controller, SearchBar-Overlay, Ziel-Modus (Pin, Bar, Sheet), Routen `search/target` | SPEC 8, 9; `client/src/lib/search/**` (+ Tests), `SearchBar.tsx`, `client/ui_*.png` | Golden-Queries · Shots · Gerät: Suche fühlt sich wie v1 an |
| **W3 Community lokal** | GRDB-Schema + Migration v1→v2, Stores, `mergeSnapshot`-Port + Tests, alle Spot-/Invite-/Friends-/Profile-Sheets, TimeTape, FABs, Toasts, Sackgassen-Regel, Routen | SPEC 3, 4, 9; `client/src/lib/spots/**` (+ Tests), `SpotSheets.tsx`, `TimeTape.tsx`, Mockups + Shots | Merge-/Store-/TimeTape-Tests · Shots aller Sheets hell+dunkel |
| **W4 CloudKit + Push** | `CloudKitService`-Port (typisiert, `Sendable`), SyncCoordinator + Outbox, Share-Accept-Adaptoren, Subscriptions, `FeedOffer` + Feed-Zone, `removeFriend`, NSE-Port + Snap-Event, Contract-Doc v2 | SPEC 7, 11; `client/ios/App/**/*.swift`; `docs/cloudkit-contract.md`; `sync.ts` | Eigener Account-Roundtrip (Spot anlegen → Share-URL → auf zweitem Gerät/Robert annehmen) · Kaltstart-Accept · Push-Banner mit Text |
| **W5 Snaps** | Kamera (AVFoundation), CapturePipeline, SnapStore + Cache + Outbox-Upload, Snap-Records/Merge/Thumb-Fetch, Album-Union, Sichtbarkeits-Schalter, Viewer, Melden/Löschen, Pins live, zusammengeführtes Spot-Sheet (nach Fable-Mockup-Abnahme) | SPEC 7, 9, 10; Spike `SpotSheet/SnapCamera/SnapViewer/SpotPinsOverlay` | Gerät: Snap frei + am Spot, auf Roberts Gerät sichtbar, Pin-Pop-in sitzt |
| **W6 Ship** | Icon/Splash aus v1, ODbL/Attribution, Wording-Sweep (konsumneutral), `aps-environment production`, Archive + Export, TestFlight Build 4 (nur auf Leons Wort), v1-Client-Archivierung planen | `store/listing-de.md` | Leon-Go pro Schritt |

Reihenfolge: W1 → (W2 ‖ W3) → W4 → W5 → W6. Ein Builder pro Welle (W2/W3 parallel = 2 Builder). Kein Builder fasst
`client/` an (Referenz bleibt unverändert, außer dem neuen Export-Skript und der Pipeline).

---

## 14. Regeln für Builder

1. SPEC-Abschnitte lesen, dann die genannten Referenzdateien — nicht raten. Abweichungen von der SPEC nur mit Begründung im Report, nie still.
2. **Nur `xcodebuild` zählt.** SourceKit-/LSP-Fehler („No such module") sind Phantome.
3. Kein `git add`/`commit` — das macht Fable nach Verify. `.dd/`, `.spm/`, `*.xcodeproj/` sind gitignored; `Package.resolved` wird eingecheckt.
4. Fixture-Daten und Debug-Routen nur `#if DEBUG`; keine Fremdfotos, keine echten Personen im Fixture-Store.
5. Wording: „Spot", „Snap", „Freunde" — nie Konsum-Vokabular in UI-Strings, Plist-Texten oder Push-Texten.
6. Env-Overrides (`GZ_ROUTE`, `GZ_HOUR`, `GZ_FIXTURES`) im Sim als **Shell-Präfix** vor `simctl launch` setzen (Argument-Form kommt still nie an).
7. Jede neue globale Ressource (Singleton, Timer, Observer) braucht einen Test-Isolationsnachweis oder Injektion.
8. Ehrlicher Report: Was Shots nicht beweisen, ist GERÄTE-TEST OFFEN.

---

## 15. Offen / später

- Zusammengeführtes Spot-Sheet (Album + Einladung + Teilnehmer): Layout-Mockup von Fable vor W5, Leon-Abnahme.
- `metersPerPixel`-Altlast (Genauigkeits-Ring ~2× zu groß in v1) — im Neubau von Anfang an mit MapLibre-Projektion korrekt rechnen.
- Personen-Picker pro Snap (v2 der Snaps): würde als eigener Share pro Snap additiv kommen.
- Bundle-Größe (61,7 MB pmtiles + places.sqlite): Zuschnitt/On-Demand erst, wenn es weh tut.
- `client/` archivieren nach Ship (README-Hinweis „v1, Referenz").
