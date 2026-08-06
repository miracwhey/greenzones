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
- Von einem Spot aus: „Einladen" → Zeit wählen (**Jetzt** oder geplant, z. B. 20:00) → Empfänger (Spot-Teilnehmer vorausgewählt, abwählbar) → senden.
- **Funktioniert von überall** — auch von zu Hause eine Einladung für einen Spot schicken. Kein Standort-Zwang, kein Standort-Broadcast: geteilt wird der SPOT, nie die eigene Live-Position.
- Empfänger: Push („Leon lädt dich ein · Unsere Bank · 20:00") → Zusagen/Absagen; Antworten sehen alle Eingeladenen.
- Eine Einladung läuft nach ihrem Zeitpunkt natürlich aus (Client blendet Vergangenes aus); Spots bleiben.
- Offline: Einladung ohne Netz → ehrlicher Abbruch mit Meldung. Spots selbst sind lokal gecacht und offline sichtbar.

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
