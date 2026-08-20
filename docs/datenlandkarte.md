# Datenlandkarte GreenZones (Neubau, `ios/`)

Stand 2026-08-18, erhoben am Code-Stand `2c1868e`. **Bindend** für
`PrivacyInfo.xcprivacy`, die Privacy Nutrition Labels im App Store, den
Abschnitt „Deine Daten" im Info-Blatt und den Privatsphäre-Schritt des
Onboardings. Jede Zeile ist am Code belegt; wo etwas nicht gefunden wurde,
steht das ausdrücklich als Nullbefund.

Wer diese Karte ändert, ändert vier Texte mit: Manifest, Store-Angaben,
Info-Blatt, Onboarding. Sie ist die eine Quelle.

---

## 1. Kurzfassung in einem Satz

GreenZones hat **keinen eigenen Server**. Alles Persönliche liegt entweder auf
dem Gerät oder in der iCloud des Nutzers; der Betreiber der App hat auf nichts
davon Zugriff. Das Gerät spricht im Betrieb mit genau **drei** fremden Stellen:
Apple iCloud (Community), `tiles.openfreemap.org` (Kartenbild) und
`photon.komoot.io` (Adresssuche).

---

## 2. Was auf dem Gerät liegt

### 2.1 Datenbank `Library/Application Support/greenzones.sqlite`

SQLite über GRDB (`Kit/Store/AppDatabase.swift:44-50`). Vier Migrationssätze:
`SearchMigrations` (`Kit/Search/RecentsStore.swift:7-27`), `CommunityMigrations`
(`Kit/Store/CommunityMigrations.swift:17-91`), `SnapMigrations`
(`Kit/Store/SnapStore.swift:6-61`); zusammengesetzt in `AppModel.swift:76-77`.

| Tabelle | Inhalt | Personenbezug |
|---|---|---|
| `recent_search` | 5 zuletzt **gewählte** Suchziele: Name, Kontextzeile, Koordinate, Quelle, Zeit | Bewegungsprofil-Andeutung — wohin jemand wollte |
| `spot` | eigene und geteilte Treffpunkte: Name, Emoji, **Koordinate**, Zeit, Zonenname, Besitzer, Share-Link | Orte, an denen sich jemand aufhält |
| `spot_participant` | wer zu welchem Spot gehört (CloudKit-Nutzer-ID) | soziale Verbindung |
| `friend` | Freundesliste: **Klartextname**, Emoji, Farbe, Zonen, `blocked` | Namen realer Personen |
| `invitation` | Termin an einem Spot: Zeit, Gastgeber, storniert | Verabredungen |
| `invitation_invitee` | wer bei diesem Termin gemeint ist | soziale Auswahl |
| `reply` | Zusage/Absage + **angekündigte Ankunftszeit** pro Person | wer wann wo sein wird |
| `setting` | eigener Anzeigename, eigenes Emoji, `profileAsked`, `migratedV1`, `seenHints` (welche In-Kontext-Hinweise schon dastanden) | eigener Name |
| `snap` | pro Foto: Autor, Zeit, **Aufnahmekoordinate**, Spot-Bezug, Sichtbarkeit, Dateipfade, Upload-Zustand, `hidden` | Aufenthaltsorte mit Zeitstempel |
| `snap_report` | welchen fremden Snap ich gemeldet habe | eigenes Meldeverhalten |
| `snap_deletion` | offene Cloud-Löschaufträge | — |

### 2.2 Bilddateien (`Kit/Snaps/SnapFiles.swift:26-28`)

| Ort | Inhalt |
|---|---|
| `Application Support/snaps/` | eigene Fotos, max. 1600 px lange Kante, JPEG q0,82 |
| `Caches/snaps/thumb/` | Vorschaubilder, 320 px — eigene und fremde |
| `Caches/snaps/photo/` | aus iCloud nachgeladene Fotos anderer |

**Die Bilder enthalten keine Metadaten.** Beim Encoden werden ausschließlich
Qualität und Orientierung geschrieben (`Kit/Snaps/SnapPipeline.swift:67-70`),
die Drehung ist in die Pixel eingebrannt. Kein GPS, keine Gerätekennung, kein
Aufnahmezeitstempel im Bild. Gegenprobe im Test: die Quelldatei *hat* GPS, beide
Ausgaben nicht (`SnapPipelineTests.swift:49-52`, `:94-99`).
Der Aufnahmeort steht stattdessen als Zahlenpaar in der Datenbankzeile.

### 2.3 UserDefaults (3 eigene Schlüssel)

`gz_onboarded` (`AppModel.swift:42,118`) · `CapacitorStorage.gz_display_name`
und `CapacitorStorage.gz_profile_emoji` (`Kit/Cloud/CloudKitGateway.swift:910-923`
— eigener Name und Emoji, doppelt zur Datenbank, weil der Beitritt über einen
Link läuft, bevor die Datenbank offen ist). Dazu die alten v1-Schlüssel, die
der Einmal-Import liest (`Kit/Store/V1Importer.swift:17-23`).

### 2.4 Mitgelieferte Dateien (statisch, ohne Nutzerbezug)

`places.sqlite` (36 MB, Ortsindex Deutschland, **read-only** geöffnet,
`Kit/Search/PlacesIndex.swift:68`) und `zones.pmtiles` (59 MB, Zonengeometrie).
In beide wird nie geschrieben; Suchanfragen landen nicht darin.

### 2.5 Nullbefunde Gerät

Kein Keychain (`kSec`/`SecItem`: 0 Treffer) · keine App-Group · kein
`NSUbiquitousKeyValueStore` · keine gespeicherte Kartenposition · **nichts
Lokales überlebt die Deinstallation.**

**Der Code-Scanner (20.08.) speichert nichts.** Er liest die Kamera nur live
zur QR-Erkennung (`AVCaptureMetadataOutput`, kein Foto-Ausgang im Graph) und
nimmt ausschließlich iCloud-Share-URLs an (`InviteLink.isShareURL`); fremde
Inhalte werden verworfen und landen weder auf der Platte noch im Protokoll.
Der gezeigte Code ist die eigene Einladungs-URL als Bild — er wird aus ihr
gerechnet (`InviteLink.qrImage`), nicht abgelegt.

---

## 3. Was das Gerät verlässt

### 3.1 Apple iCloud (CloudKit) — Container `iCloud.de.leonvalentin.greenzones`

Nur **private** und **geteilte** Datenbank, **keine öffentliche**
(`publicCloudDatabase`: 0 Treffer). Alles liegt im iCloud-Konto des jeweiligen
Nutzers. Der Betreiber der App hat darauf keinen Zugriff und kann ihn sich auch
nicht verschaffen.

| Record | Felder | Wer liest mit |
|---|---|---|
| `Friendship` | `createdAt` | die zwei Personen |
| `Profile` | `name`, `emoji` | verbundene Freunde |
| `SpotOffer` | `spotShareURL`, `spotName`, `spotEmoji` | der eingeladene Freund |
| `FeedOffer` | `feedShareURL` | alle Freunde |
| `Spot` | `name`, `emoji`, **`lat`**, **`lng`**, `createdAt` | alle Spot-Mitglieder |
| `Invitation` | `time`, `createdAt`, `cancelled`, `inviteeIds` | alle Spot-Mitglieder |
| `Reply` | `invitationId`, `status`, `arrivalTime` | alle Spot-Mitglieder |
| `Feed` | `createdAt` | alle Freunde |
| `Snap` | `createdAt`, **`lat`**, **`lng`**, `thumb` (Bild), `photo` (Bild), `spotZone`, `spotName`, `spotEmoji` | Feed-Snap: alle Freunde · Spot-Snap: Spot-Mitglieder |

Einen zehnten Typ `Report` gab es bis zum 18.08. — siehe B3, er ist entfallen.

Die Nutzer-Kennung ist durchgehend die CloudKit-`userRecordID` — eine
container-eigene Kennung. **Weder iCloud-Name noch Apple-ID, E-Mail oder
Telefonnummer werden gelesen** (`nameComponents`, `discoverUserIdentity`,
`lookupInfo`, `emailAddress`, `phoneNumber`, `CKUserIdentity`: 0 Treffer). Der
Anzeigename ist der selbst getippte aus `ProfileEditor.swift:70-74`.

**Zwei Koordinatenpaare verlassen das Gerät, beide punktuell und
nutzerausgelöst:** die Koordinate eines angelegten Spots
(`CloudKitGateway.swift:292-293`, voreingestellt der eigene Standort) und der
Aufnahmeort eines Snaps (`CKSnapRecord.swift:17-18`). **Eine laufende Position
wird nie übertragen** — es gibt kein Feld dafür, keinen Hintergrund-Modus und
der `LocationService` kennt CloudKit nicht.

### 3.2 `tiles.openfreemap.org` — das Kartenbild

Die Grundkarte ist **nicht** offline: Vektorkacheln, Schriften und Symbole
kommen von dort. Bei jeder Kartenbewegung gehen Kachelkoordinaten dorthin, also
**der betrachtete Ausschnitt plus IP-Adresse**. Betreiber ist OpenFreeMap, nicht
GreenZones.

**Der Style selbst liegt seit dem 18.08. im Bundle**
(`GreenZones/Resources/Map/style-{positron,dark}.json`, in `project.yml` einzeln
gelistet). Vorher wurde auch er geladen — und weil die Zonen-Layer in
`didFinishLoading style:` eingehängt werden, hing die **Zonen-Anzeige** damit am
Netz: ohne Empfang eine leere Fläche, obwohl `zones.pmtiles` im Bundle liegt.
Im Bild nachgestellt und bestätigt. Jetzt zeigt die Karte ohne Netz die
vollständigen Zonen, es fehlen nur Straßen, Namen und Wasser.

Die Kachel-Quelle bleibt bewusst eine `url:`-Referenz auf das TileJSON: die
Kachel-Adresse darin trägt einen Datumsstempel des Datensatzes und würde fest
eingebacken irgendwann auf einen abgeräumten Stand zeigen.

Ohne Netz bleiben Rechtsstatus, Zonenflächen, Ortssuche und alle lokalen Daten
nutzbar. Für das Kartenbild gibt es zwei Vorräte (`Services/OfflineMapStore.swift`):
der Zwischenspeicher von MapLibre, jetzt auf 400 MB gesetzt statt im
unkonfigurierten Standard, und ein **auf Wunsch gesichertes Gebiet** von 20 × 20 km
um den eigenen Standort bis Zoom 14 (~70 MB, im Info-Blatt unter „Karte
offline"). Gemessene Grundlage: eine Kachel wiegt bei Zoom 14 im Stadtgebiet
~350 KB, bei Zoom 13 ~86 KB; ganz Deutschland bis Zoom 14 wären ~20 GB und
scheidet damit aus.

Das gesicherte Gebiet ist eine Kopie fremder Kacheln auf dem Gerät — es
verlässt es nicht und ändert an §3 nichts.

### 3.3 `photon.komoot.io` — die Adresssuche

`Kit/Search/PhotonClient.swift:36`. Mitgesendet werden **nur** der Suchbegriff,
`limit=5`, `lang=de` und eine feste Deutschland-Bounding-Box
(`PhotonClient.swift:37-40`), dazu unvermeidbar IP und Zeitpunkt.
**Die Position des Nutzers geht nicht mit** — sie wirkt ausschließlich auf das
lokale Ranking (`SearchController.swift`, `setUserPos`). Kein Schlüssel, keine
Gerätekennung, keine Sitzungs-ID.

**Und nur auf Ansage:** Tippen erreicht Komoot nicht. Die Liste bietet „Nach
Adressen suchen" an, ausgelöst wird über `SearchController.searchOnline()` — per
Knopf oder Return-Taste. Ein Test hält fest, dass keine Tippfolge, wie lang auch
immer, eine Anfrage erzeugt.

### 3.4 Nullbefund Telemetrie

Keine Analytik, kein Absturzmelder, keine Werbe-Kennung, kein Tracking. Geprüft
gegen 30 Anbieternamen und die einschlägigen APIs (`ATTrackingManager`,
`advertisingIdentifier`, `MetricKit`): 0 echte Treffer. Es gibt genau zwei
Fremdbibliotheken — MapLibre 6.28.0 und GRDB 7.11.1, beide mit eigenem
Privacy-Manifest. `URLSession` wird an **einer** Stelle im ganzen Projekt
benutzt: für Photon.

---

## 4. Befunde der Erhebung und ihr Stand

Erhoben am 18.08. an `2c1868e`. Was seitdem behoben ist, steht als **erledigt**
mit dem, was gemacht wurde — die offenen Punkte darunter sind die ehrliche
Restliste.

**B1 — erledigt. Der Standort-Erlaubnistext sagte die Unwahrheit.**
`NSLocationWhenInUseUsageDescription` endete mit „Dein Standort bleibt auf dem
Gerät." Für die laufende Ortung stimmt das; ein angelegter Spot und ein Snap
tragen die Position aber in die geteilte iCloud. Der Text nennt jetzt beides,
der Kamera-Text sagt zusätzlich, dass die Fotomediathek nie angefasst wird.

**B2 — erledigt. Die Mitteilungs-Erweiterung lud bei jedem Push alle Fotos.**
Sie rief den Vollabzug **ohne** `desiredKeys`, also samt aller Bildanhänge, in
einen Prozess mit hartem Speicherlimit; die App rief an gleicher Stelle die
schlanke Fassung. Der Kommentar über der schlanken Fassung nannte genau diesen
Fall „Pflicht" — gerufen wurde die andere. Das ist der wahrscheinlichste Grund,
warum ein Banner mit echtem Text auf dem Gerät nie ankam. Behoben nicht durch
Umbiegen des Aufrufs, sondern durch **Löschen der Fassung ohne Feldliste**: es
gibt nur noch eine Leseart, und die verlangt `desiredKeys`. Ein Vertragstest
hält fest, dass die Feldliste nie ein Bildfeld enthält.

**B3 — erledigt (Leon-Entscheid). Melden ist entfallen.**
`Report` wurde in die Zone des Snap-Autors geschrieben; recordName und
`creatorUserRecordID` benannten den Melder, und der Autor ist Eigentümer der
Zone. Gelesen hat die Records nie jemand — ohne Server gibt es keine Stelle, die
moderiert. Der Record nützte nichts und schadete dem Melder. Geblieben ist, was
wirkt: **Ausblenden** (dauerhaft, überlebt jeden Abzug) und **Person entfernen**,
beides im selben Dialog. Record-Typ, Schreibweg und Vermerk-Tabelle sind weg.
→ Gehört in die Review-Notes: geschlossener Kreis per Einladungslink, kein
öffentlicher Inhalt, keine Entdeckung Fremder, Blockieren vorhanden.

**B4 — erledigt. Die Erweiterung schrieb Freundesnamen ins Systemprotokoll.**
Titel und Text des Banners gingen mit `privacy: .public` in den Log-Store, der
die App überlebt. Jetzt geht nur noch die Diagnose-Frage raus: betextet ja/nein.

**B5 — offen, bewusst. Ein weitergereichter Einladungslink gibt Schreibrecht.**
Alle Freigaben stehen auf `publicPermission = .readWrite`
(`CloudKitGateway.swift:155`, `:782`). Wer den Link hat, ist Teilnehmer und darf
schreiben — auch wenn er ihn von jemand anderem bekommen hat. Das ist die
gleiche Klasse wie die App-Trennung bei `inviteeIds`: eine Einladung ist ein
Schlüssel, kein Ausweis. Gilt unverändert für den QR-Code (20.08.): er trägt
dieselbe Share-URL als Bild — abfotografiert ist er derselbe Schlüssel.

**B6 — halb erledigt. Der Suchverlauf ließ sich nicht löschen.**
`RecentsStore.clear()` existierte seit W2 ohne Aufrufer; der X-Knopf leert nur
das Eingabefeld. Jetzt gibt es „Zuletzt gesucht löschen" im Info-Blatt.
**Weiterhin offen:** kein Weg, alle lokalen Daten auf einmal zu löschen, und
keiner, das eigene Profil zu entfernen. Die Deinstallation nimmt alles Lokale
mit (§2.5) — das ist die Antwort, solange es keinen Reset gibt.

**B7 — erledigt. Die Adresssuche fragte beim Tippen.**
Ab drei Zeichen ging 300 ms nach jedem Tippstopp ein Präfix an Komoot, auch im
Flugmodus (`isOnline` ist in Produktion konstant `true`). Jetzt bietet die Liste
„Nach Adressen suchen" an und fragt erst auf Druck; die Return-Taste tut
dasselbe. Der Debounce ist mit seinem Anlass entfallen.

**B8 — offen. Reste bleiben liegen.** „Freund entfernen" setzt nur
`blocked = 1`, der Name bleibt lokal stehen (`SyncCoordinator.swift:399-405`) ·
Snaps überleben das Löschen ihres Spots samt Koordinate und Datei · verwaiste
Bilddateien sammelt niemand ein (genau ein `removeItem` im Projekt) · die alten
v1-Schlüssel in den UserDefaults werden nach dem Import nie gelöscht.

**B9 — entschieden (Leon). Die Store-Angabe lautet „Keine Daten erfasst".**
Apples Definition von „erfassen" verlangt Zugriff des Anbieters; den gibt es
hier nicht — es existiert kein Server, und die private wie die geteilte
CloudKit-Datenbank liegen im iCloud-Konto der Nutzer. Apple äußert sich zu
CloudKit-Freigaben nirgends ausdrücklich, deshalb erklärt eine Zeile in den
Review-Notes den Aufbau.

**B10 — erledigt. Bestandsnutzer hätten kein Onboarding gesehen.**
`shouldShowOnboarding` war `!onboarded && !location.isAuthorized`. Build 4
ersetzt die TestFlight-App unter derselben Bundle-ID, dort ist die Ortung längst
erlaubt — das Onboarding wäre bei niemandem angekommen, der die App schon hat.
Die Frage hängt jetzt allein am eigenen Zähler `gz_onboarded_v2`.

---

## 5. Ableitung fürs Manifest (`PrivacyInfo.xcprivacy`)

- `NSPrivacyTracking`: `false` · `NSPrivacyTrackingDomains`: leer — belegt
  durch den Nullbefund in 3.4.
- `NSPrivacyAccessedAPITypes`: **nur** `NSPrivacyAccessedAPICategoryUserDefaults`
  mit Grund `CA92.1` (ausschließlich app-eigene Daten, kein Teilen).
  Nullbefund für Dateizeitstempel, Systemstartzeit, Speicherplatz und aktive
  Tastaturen — die `CKRecord.creationDate`-Treffer sind CloudKit-Felder, keine
  Dateiattribute.
- `NSPrivacyCollectedDataTypes`: hängt an B9.
