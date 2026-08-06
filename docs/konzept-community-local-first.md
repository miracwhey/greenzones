# Community-Feature — Local-first-Konzept (bindend)

Stand: 2026-08-06 (v2 — Leon-Korrektur: persistente Spots + Einladungen statt ephemerem Check-in; Freunde statt Crew-Zwang) · Status: **Entwurf, wartet auf Leons Abnahme** · Gilt nach Abnahme als Design-Gate für den Build.

## Produktregeln (die Verfassung)

1. **Standard = lokal.** Jede Information bleibt auf dem Gerät, außer sie MUSS übertragen werden, damit ein Freund sie sehen kann.
2. **Teilen ist immer explizit, an konkrete Personen, widerrufbar** — und mit Ablaufdatum, wo es der Sache nach passt (Check-ins).
3. **Kein eigener Server. Keine Registrierung. Keine Telemetrie.** Wir KÖNNEN die Daten nicht sehen — nicht „wir schauen nicht hin", sondern „es gibt bei uns nichts, wo sie liegen".
4. **Offline ist Normalzustand, kein Fehlerfall.** Alles Lokale funktioniert immer. Geteiltes: Dauerhaftes wird nachgeliefert, sobald Netz da ist; Flüchtiges (Check-in) wird ehrlich abgebrochen statt verspätet zugestellt.
5. **Apple-only ist okay** (Leon-Entscheid 2026-08-06). Android ist mit dieser Architektur ausgeschlossen — bewusst.

## Drei Daten-Schubladen

| Schublade | Inhalt | Wo liegt es | Verlässt Gerät? |
|---|---|---|---|
| **A — nur meins** | Konsum-Journal, Such-Verlauf/Recents, Einstellungen, eigener Standort(verlauf) | Gerät (Filesystem/lokale DB) | **Nie** |
| **B — geteilt mit Freunden** | Spots, Einladungen, Spot-Fotos, Freundesliste, Anzeigename | Geteilte iCloud-Bereiche (CloudKit CKShare) | Nur an die jeweiligen Teilnehmer |
| **C — für alle** | Zonen-Daten, Orte-Index (165k) | Im App-Bundle / als Download | Kommt ZUM Gerät, nicht vom Gerät |

Regel bei jedem neuen Feature: erst einordnen — A, B oder C? Gibt es Zweifel, ist es A.

## Objektmodell: Freunde · Spots · Einladungen (Leon-Modell, „wie Pokémon Go")

**Freunde** — personenbasiert, einzeln hinzugefügt:
- Hinzufügen per **Einladungslink** (Share-Sheet → iMessage/WhatsApp/beliebig). Kein Nutzerverzeichnis, kein Kontakte-Upload, keine Handynummern/E-Mails.
- Identität: **frei wählbarer Anzeigename**. Account = Apple-ID implizit via CloudKit, für Nutzer unsichtbar — kein Login-Screen.
- Entfernen/Blockieren = Zugriff sofort weg (CKShare-Teilnehmer entfernen).

**Spots** — persistente, benutzerdefinierte Orte. Das Herzstück:
- „Unsere Bank": am eigenen Standort markieren ODER Punkt auf der Karte wählen. Name + Icon/Emoji.
- Spot **bleibt dauerhaft auf der Karte** — für mich und alle Freunde, mit denen er geteilt ist (Sichtbarkeit pro Spot wählbar: welche Freunde „haben" diesen Spot).
- Die App rechnet den **Legal-Status des Spots** automatisch dazu (erlaubt / Verbotszone-Distanz) — Alleinstellungsmerkmal gegenüber jeder generischen Karten-App.
- Technisch: 1 Spot = 1 geteilter CloudKit-Record-Baum (CKShare), Teilnehmer = die eingeladenen Freunde. Einladungen und später Fotos hängen als Child-Records am Spot.

**Einladungen (Sessions)** — die Verabredungs-Mechanik:
- Von einem Spot aus: „Einladen" → Zeit wählen (Zeit-Band, s. u.) → Empfänger (Spot-Teilnehmer vorausgewählt, abwählbar) → senden.
- **Funktioniert von überall** — auch von zu Hause eine Einladung für einen Spot schicken. Kein Standort-Zwang, kein Standort-Broadcast: geteilt wird der SPOT, nie die eigene Live-Position.
- Empfänger: Push („Leon lädt dich ein · Unsere Bank · 20:00") → antworten (s. „Antworten: jeder sagt seine Zeit"); Antworten sehen alle Eingeladenen.
- Eine Einladung läuft nach ihrem Zeitpunkt natürlich aus (Client blendet Vergangenes aus); Spots bleiben.
- Offline: Einladung ohne Netz → ehrlicher Abbruch mit Meldung. Spots selbst sind lokal gecacht und offline sichtbar.

### Zeitwahl: das Zeit-Band (v2.1, Leon-Prio „deutlich intuitiver als 3 Chips")

**Ein draggbares Zeit-Band (Tape) unter fixem Cursor** — wie Kamera-Zoom/Timer, statt kuratierter Chips. Direkte Manipulation: jede Zeit ist erreichbar, nicht nur vorgegebene Griffe.

- Bereich **Jetzt … +36 h**, Snap auf runde Viertelstunden (absolute Uhrzeit, nie „jetzt + k·15"). Linkes Ende hat eine **„Jetzt"-Rastzone** (< 8 min → Anzeige „Jetzt", CTA „Jetzt einladen").
- Große Live-Anzeige („Heute · 20:00" + „in 10 Std 19 Min"), Stunden-Ticks mit Labels, Tagesgrenzen als „MORGEN"-Marker im Band.
- **Anker-Chips („Jetzt" · „Heute Abend" · „Morgen Abend") sind nur Sprungmarken aufs Band** — es animiert dorthin und bleibt frei justierbar. Kein Rückfall in Chip-Auswahl.
- **Legal-Status live zur gewählten Zeit:** unterm Band steht „Am Spot um 20:00 erlaubt" und rechnet beim Ziehen mit — bei Spots nahe Fußgängerzonen (7–20 Uhr) kippt der Status sichtbar mit der Uhrzeit. Das macht den Picker zum GreenZones-Feature statt zu einem generischen Datepicker.
- **Dasselbe Band überall:** Einladung senden, eigene Ankunftszeit nennen, Host-Zeit nachträglich ändern — eine gelernte Geste für alles. Bei „Ich komme um …" ist die Host-Zeit als **„Leon ab 20:00"-Flagge** im Band markiert, beim Host-Ändern eine „bisher"-Flagge (erscheint erst beim Wegziehen).
- Im echten Build: Haptik-Ticks beim Snappen (UIImpactFeedbackGenerator via Plugin).

### Antworten: jeder sagt seine Zeit (v2.2 — Leon-Korrektur, ersetzt das Verhandlungs-Modell)

**Kein Konsens-Protokoll.** Die Host-Zeit ist ein Anker („Ich bin ab 20:00 da"), kein Termin, der für alle verhandelt wird. Es gibt keinen Entscheidungs-Flow, keine Übernahme, nichts stellt sich für andere um — wie im echten Leben: „Bin ab 8 da" — „ich komm um 9". Fertig.

- Antwortraum des Empfängers: **„Bin dabei"** (zur Host-Zeit) · **„Ich komme um …"** (Band, vorpositioniert auf Host-Zeit) · **„Kann nicht"**.
- „Ich komme um 21:00" **gilt als Zusage mit eigener Ankunftszeit** — für niemanden sonst ändert sich etwas. Alle sehen in der Teilnehmerliste, wer wann kommt: „Leon ab 20:00 · Marcel dabei · Tara kommt um 21:00".
- Der Host bekommt Antworten **nur als Push** („Tara kommt um 21:00") — kein Screen, der eine Entscheidung verlangt.
- Karten-Pin zeigt die Anker-Zeit: „ab 20:00".

### Nachträglich ändern & absagen (v2.2)

- **Host ändert seine Anker-Zeit** direkt: Einladungs-Detail → „Deine Zeit" → gleiches Band → Push an alle. **Antworten bleiben bestehen** (haben ja eigene Zeiten) — wer nicht mehr kann, meldet sich neu.
- Eingeladene ändern ihre eigene Ankunftszeit jederzeit über dieselbe „Ich komme um …"-Mechanik.
- **Host kann die Einladung absagen** → Push an alle, Session verschwindet, **der Spot bleibt**.

**CloudKit-Mapping (konfliktfrei by design):** Einladung = Child-Record am Spot, nur der Host schreibt ihn (Feld `time` = Anker-Zeit). Antwort = ein Child-Record **pro Teilnehmer**, nur der jeweilige Teilnehmer schreibt ihn (`status: dabei|absage`, optional `arrivalTime`). Jeder Record hat genau einen Schreiber → keine Merge-Konflikte, keine Abstimmungs-Zustände.

**Mockup (bindend nach Abnahme):** `mockup/invite.html` — klickbar mit Rollenwechsel Leon⇄Tara (kompletter Loop spielbar), Screenshot-Szenarien `iv_*.png` (`?s=picker|picker-idle|push|received|mytime|answered-host|manage|edit|updated`), Interaktionstest `mockup/test_invite.mjs`.

## Weitere Phasen

### Spot-Fotos (Phase 2)
- Foto am Spot hinterlassen, **sichtbar nur für die Spot-Teilnehmer** (CKAsset als Child-Record am Spot).
- Lokal-first: Aufnahme funktioniert offline → Outbox → Upload bei Netz. Empfangene Fotos werden lokal gecacht → offline ansehbar.
- UGC-Pflichten (Apple 1.2) im privaten Kreis minimal: Melden + Blockieren + Teilnehmer entfernen reichen.

### Konsum-Tracking (Phase 3, optional)
- Schublade A, **komplett lokal**, geht nie ins Netz. Kein Cloud-Sync, kein Opt-in-Server.
- Sicherung: über normales iPhone-Backup abgedeckt (verschlüsselt, Apples Sache). Optionaler iCloud-Sync fürs Journal nur, falls Leon es später explizit will.

## Push & Wording (Apple-Gate)

- Push technisch: CKQuerySubscription auf Einladungs-/Antwort-Records → sichtbare Remote-Notification, kein eigener Push-Server.
- **Store-Fassade konsumneutral:** Screenshots/Metadata/Push-Texte sprechen von „Spot", „Treffpunkt", „eingecheckt" — nie Konsum-Aufforderung („Komm rauchen" o. ä.). Guideline 1.4.3 (encourage consumption) ist ein hartes Rejection-Risiko. In-App-Tonalität darf lockerer sein, die nach außen sichtbare Fassade bleibt clean. 18+ Rating, Vertrieb DE.

## Privacy-Label-Ziel

Keine public Database, kein Server, keine Analytics → Ziel ist das App-Store-Label **„Keine Daten erhoben"**. Vor Store-Submission gegen Apples aktuelle Label-Regeln verifizieren, nicht blind behaupten.

## Technischer Brocken (ehrlich)

CloudKit aus dem Capacitor-WebView braucht ein **eigenes natives Plugin** (Swift: CKContainer, CKShare-Flow inkl. Accept-Handling, Subscriptions, Asset-Up/Download). Das ist der Hauptaufwand von Phase 1 — vor dem Feature-Build als eigener Schritt bauen und auf Gerät beweisen (Share-Accept-Flow ist der fummeligste Teil, zuerst als Spike).

## Reihenfolge

1. ✅ Bottom-Sheet-Umbau (StatusBar, committet).
2. Mockups Spots+Einladungen-Flow (Spot anlegen, Karte mit Spots, Einladung senden — auch remote, Empfänger-Push, Freundesliste) → Leons Abnahme.
3. CloudKit-Plugin-Spike (Share-Accept auf 2 echten Geräten beweisen).
4. Build Phase 1: Freunde + Spots + Einladungen/Push.
