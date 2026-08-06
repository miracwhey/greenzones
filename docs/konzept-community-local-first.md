# Community-Feature — Local-first-Konzept (bindend)

Stand: 2026-08-06 · Status: **Entwurf, wartet auf Leons Abnahme** · Gilt nach Abnahme als Design-Gate für den Build.

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
| **B — für meine Crew** | Check-ins, Spot-Fotos, Crew-Mitgliedschaft, Anzeigename | Geteilte iCloud-Zone der Crew (CloudKit shared zone) | Nur an Crew-Mitglieder |
| **C — für alle** | Zonen-Daten, Orte-Index (165k) | Im App-Bundle / als Download | Kommt ZUM Gerät, nicht vom Gerät |

Regel bei jedem neuen Feature: erst einordnen — A, B oder C? Gibt es Zweifel, ist es A.

## Crew-Modell (statt Einzelfreundschaften)

- Grundeinheit = **Crew** (Freundesgruppe), nicht Einzelfreund. Passt zur Realität (Kiffen = Gruppenritual) und ist technisch sauberer: 1 Crew = 1 geteilte CloudKit-Zone (CKShare).
- **Beitritt per Einladungslink** (Share-Sheet → iMessage/WhatsApp/beliebig). Kein Nutzerverzeichnis, kein Kontakte-Upload, keine Handynummern/E-Mails.
- Mehrere Crews möglich (Kollegen ≠ Schulfreunde). Inhalte sind strikt pro Crew getrennt.
- **Verlassen/Rauswerfen = Zugriff sofort weg** (CKShare-Teilnehmer entfernen).
- Identität: **frei wählbarer Anzeigename** (pro Crew änderbar). Account = Apple-ID implizit via CloudKit, für Nutzer unsichtbar — kein Login-Screen.

## Features auf dieser Basis

### Session-Ping (Kern, Phase 1)
- Check-in an Spot aus der Karte → Record in Crew-Zone → CloudKit-Subscription pusht an Crew.
- Freunde sehen Check-in als Pin auf der Karte.
- **TTL 2 h.** CloudKit löscht nicht automatisch → Clients ignorieren abgelaufene Records beim Lesen und löschen sie opportunistisch.
- Kein Dauer-Standort-Tracking. Nur der eine, bewusst geteilte Moment.
- Offline: Check-in ohne Netz → ehrlicher Abbruch mit Meldung (Flüchtiges wird nie gequeued — verspäteter Check-in ist Falschinformation).

### Spot-Fotos (Phase 2)
- Foto an Ort hinterlassen, **sichtbar nur für die Crew** (CKAsset in Crew-Zone).
- Lokal-first: Aufnahme funktioniert offline → Outbox → Upload bei Netz. Empfangene Crew-Fotos werden lokal gecacht → offline ansehbar.
- UGC-Pflichten (Apple 1.2) im privaten Kreis minimal: Melden + Blockieren + Crew-Rauswurf reichen.

### Konsum-Tracking (Phase 3, optional)
- Schublade A, **komplett lokal**, geht nie ins Netz. Kein Cloud-Sync, kein Opt-in-Server.
- Sicherung: über normales iPhone-Backup abgedeckt (verschlüsselt, Apples Sache). Optionaler iCloud-Sync fürs Journal nur, falls Leon es später explizit will.

## Push & Wording (Apple-Gate)

- Push technisch: CKQuerySubscription auf Check-in-Records → sichtbare Remote-Notification, kein eigener Push-Server.
- **Store-Fassade konsumneutral:** Screenshots/Metadata/Push-Texte sprechen von „Spot", „Treffpunkt", „eingecheckt" — nie Konsum-Aufforderung („Komm rauchen" o. ä.). Guideline 1.4.3 (encourage consumption) ist ein hartes Rejection-Risiko. In-App-Tonalität darf lockerer sein, die nach außen sichtbare Fassade bleibt clean. 18+ Rating, Vertrieb DE.

## Privacy-Label-Ziel

Keine public Database, kein Server, keine Analytics → Ziel ist das App-Store-Label **„Keine Daten erhoben"**. Vor Store-Submission gegen Apples aktuelle Label-Regeln verifizieren, nicht blind behaupten.

## Technischer Brocken (ehrlich)

CloudKit aus dem Capacitor-WebView braucht ein **eigenes natives Plugin** (Swift: CKContainer, CKShare-Flow inkl. Accept-Handling, Subscriptions, Asset-Up/Download). Das ist der Hauptaufwand von Phase 1 — vor dem Feature-Build als eigener Schritt bauen und auf Gerät beweisen (Share-Accept-Flow ist der fummeligste Teil, zuerst als Spike).

## Reihenfolge

1. Bottom-Sheet-Umbau (bereits gelockte Prio 1) — beim Redesign Slot für Freunde-Pins/Status mitdenken.
2. Mockup Session-Ping-Flow (Check-in, Push, Friend-Pin, Crew-Beitritt) → Leons Abnahme.
3. CloudKit-Plugin-Spike (Share-Accept auf 2 echten Geräten beweisen).
4. Build Phase 1.
