# Store-Angaben GreenZones 2.0

Stand 18.08.2026. Gilt für App-ID **6798829082**, `MARKETING_VERSION 2.0`,
`CURRENT_PROJECT_VERSION 4`.

Alle Texte hängen an `docs/datenlandkarte.md` — wer dort etwas ändert, ändert
hier mit. Und sie sind **konsumneutral** formuliert (App Store Review 1.4.3):
die App beschreibt, wo das Gesetz Grenzen zieht, sie fordert zu nichts auf,
bewirbt nichts und nennt keine Bezugsquellen.

⚠️ Nichts davon ist eingetragen. Das Eintragen geschieht in der Web-UI von App
Store Connect (die API darf keine App-Infos anlegen) — und erst auf Leons Wort.

---

## Kurzfelder

| Feld | Inhalt | Länge |
|---|---|---|
| **Name** | `GreenZones` | 10 / 30 |
| **Untertitel** | `Wo §5 KCanG Grenzen zieht` | 25 / 30 |
| **Werbetext** (jederzeit änderbar) | `Neu: Karte auch ohne Netz, Spots mit Freunden, Bilder im eigenen Kreis.` | 71 / 170 |
| **Keywords** | `KCanG,Cannabisgesetz,Konsumverbot,Schutzzone,Karte,Abstand,100 Meter,Fußgängerzone,Recht,Offline` | 98 / 100 |
| **Primäre Kategorie** | Referenz | — |
| **Sekundäre Kategorie** | Navigation | — |
| **Copyright** | `2026 Leon Karim Valentin` | — |

**Kategorie-Begründung:** die App schlägt nichts vor und führt niemanden
irgendwohin — sie beantwortet eine Rechtsfrage für einen Ort. „Referenz" ist die
ehrliche Einordnung und hält die App aus Lifestyle-Vergleichen heraus.
„Navigation" als zweite Kategorie deckt die Karte ab.

---

## Beschreibung (de-DE)

```
GreenZones zeigt auf einer Karte, wo das Konsumcannabisgesetz Grenzen zieht —
für deinen Standort, zur aktuellen Uhrzeit.

§5 Abs. 2 KCanG verbietet öffentlichen Konsum in Sichtweite von Schulen,
Kinderspielplätzen, Kinder- und Jugendeinrichtungen sowie öffentlich
zugänglichen Sportstätten — gerechnet als 100 Meter vom Eingangsbereich — und in
Fußgängerzonen zwischen 7 und 20 Uhr. Diese Flächen sind schwer im Kopf zu
haben. GreenZones macht sie sichtbar.

SO LIEST SICH DIE KARTE
• Rote Flächen: 100 m um Schulen, Kitas, Spielplätze und Sportstätten.
• Orange Flächen: Fußgängerzonen, verboten von 7 bis 20 Uhr, danach frei.
• Alles andere: kein Verbot nach §5 KCanG.
Eine Zeile am unteren Rand sagt dir jederzeit, woran du gerade bist, und wie
weit die nächste Grenze entfernt liegt.

SUCHEN, WO DU HINWILLST
Parks, Seen, Plätze und Bahnhöfe findest du sofort — der Ortsindex liegt in der
App und braucht kein Netz. Adressen sucht auf Wunsch Komoot, aber erst, wenn du
danach fragst.

AUCH OHNE EMPFANG
Die Zonen liegen vollständig auf dem Gerät. Wer vorher „Umgebung sichern"
antippt, hat auch das Kartenbild dabei — 20 x 20 km um den eigenen Standort.

ORTE, DIE EUCH GEHÖREN
Ein Spot ist ein fester Platz, den du mit Freunden teilst: eure Bank, euer Park.
Freunde entstehen über einen Link — ohne Konto, ohne Adressbuch. Zu einem Spot
kannst du für eine Zeit einladen; jeder antwortet mit seiner eigenen Ankunft.
Geteilt wird immer der Ort des Spots — nie, wo du gerade bist.

BILDER IM EIGENEN KREIS
Snaps entstehen live in der App, nie aus der Mediathek. Sie landen am Spot in
der Nähe oder als eigener Pin auf der Karte. Wer sie sieht, entscheidest du:
alle deine Freunde oder nur die, die zu diesem Spot gehören. In der Bilddatei
steht weder Koordinate noch Gerätespur.

DEINE DATEN BLEIBEN DEINE
GreenZones hat keinen Server. Spots, Freunde, Termine und Bilder liegen auf
deinem Gerät und in deiner iCloud — außer den Freunden, denen du sie gibst,
kommt niemand daran. Kein Konto, keine Anmeldung, keine Werbung, keine
Statistik über dich.

KEIN RECHTSRAT
GreenZones ist eine Orientierungshilfe ohne Gewähr auf Richtigkeit oder
Vollständigkeit. Die Zonen werden aus OpenStreetMap-Daten berechnet, und
OpenStreetMap kennt nicht jede Einrichtung. Maßgeblich ist das Gesetz, die
Verantwortung bleibt bei dir.

Kartendaten © OpenStreetMap-Mitwirkende (ODbL), Kartenbild von OpenFreeMap.
```

Länge: rund 2 100 Zeichen von 4 000.

---

## Versionshinweise „Was ist neu" (2.0)

```
GreenZones ist neu gebaut — direkt in Swift, damit Karte und Bewegungen so
laufen, wie iOS es kann.

• Karte und Zonen auch ohne Empfang; die Umgebung lässt sich vorher sichern.
• Spots mit Freunden: einladen per Link, Termine mit eigener Ankunftszeit.
• Snaps: live aufgenommen, sichtbar nur im gewählten Kreis, ohne Ort in der Datei.
• Vier Schritte zu Beginn erklären Karte, Datenwege, Spots und Bilder.
• Ortssuche ohne Netz; Adressen werden erst auf Nachfrage gesucht.
```

---

## Pflicht-Adressen

| Feld | Wert | Stand |
|---|---|---|
| **Support-URL** | `https://miracwhey.github.io/greenzones-web/` | ✅ live |
| **Datenschutz-URL** | `https://miracwhey.github.io/greenzones-web/datenschutz.html` | ✅ live |
| **Marketing-URL** | — | freiwillig, bleibt leer |

**Entschieden 18.08. (Leon: „schau selbst was gut für uns ist"):** GitHub Pages
aus dem öffentlichen Repo `miracwhey/greenzones-web`. Quelle liegt in `web/`
dieses Repos und wird von dort kopiert.

Vercel schied aus: der Account meldet beim Deploy `402 — Your team has an
overdue balance`. Cloudflare Pages hätte ein weiteres Konto und `wrangler`
gebraucht. GitHub Pages kostet nichts, das Konto steht, und die Seite ist ohne
Buildschritt statisch.

Die Startseite ist zugleich Support-Seite (häufige Fragen + Kontakt) und trägt
die Anbieterangaben nach §5 DDG; die Erklärung liegt eine Seite weiter. Beide
in hell und dunkel, sie folgen dem System.

---

## Datenschutz-Angaben im Store (Nutrition Labels)

**„Keine Daten erfasst"** (Leon-Entscheid 18.08., B9 der Datenlandkarte).

Begründung, die in die Review-Notes gehört: Apples Definition von „erfassen"
verlangt Zugriff des Anbieters auf die Daten. Den gibt es hier nicht — es
existiert kein Server, und private wie geteilte CloudKit-Datenbank liegen im
iCloud-Konto der Nutzer. Das deckt sich mit dem Privacy-Manifest
(`PrivacyInfo.xcprivacy`): kein Tracking, keine Tracking-Domains, als
API-Nutzung nur `UserDefaults` mit Grund `CA92.1`.

---

## Altersfreigabe

Im Fragebogen ist **eine** Frage einschlägig: Hinweise auf Drogen oder Alkohol.

**Von Leon bestätigt (18.08.): „Selten/schwach" (Infrequent/Mild) → 17+.**

Warum nicht „keine": die App nennt Cannabis beim Namen und bezieht sich auf das
Konsumcannabisgesetz. Eine Einstufung, die das verschweigt, wäre angreifbar —
und ein Rückläufer im Review kostet mehr als die höhere Altersgrenze. Warum
nicht „häufig/stark": es gibt keine Darstellung von Konsum, keine Anleitung,
keine Bezugsquelle; das Thema ist der räumliche Geltungsbereich eines Gesetzes.

17+ ist außerdem stimmig zum Gesetz selbst: KCanG gilt für Erwachsene.

---

## Screenshots

Pflicht ist **ein** Satz für 6,9 Zoll (1320 x 2868). Ältere Größen darf Apple
daraus ableiten.

**Aufgenommen am 18.08., Simulator iPhone 17 Pro Max, 1320 x 2868 nachgemessen,
Statusleiste auf 9:41 festgesetzt.** Sie liegen in `ios/shots/store/`
(gitignoriert, überleben aber die Sitzung):

| Datei | Zeigt |
|---|---|
| `01_karte.png` | Karte mit Zonen, Standort, Statuszeile „Hier erlaubt · Verbotszone 109 m" |
| `02_suche.png` | Suche „masch" mit sechs Ortstreffern und Entfernungen |
| `03_zugang.png` | „Wer sieht ,Unsere Bank‘?" — Zugang als Auswahl |
| `04_termin.png` | Einladen mit Zeitband, „Nur die Angehakten bekommen Bescheid" |
| `05_daten.png` | Onboarding „Deine Daten bleiben deine" |
| `06_offline.png` | „Karte & Daten" mit „Umgebung sichern (20 km, ca. 70 MB)" |

**Das sind rohe Gerätebilder, noch kein Store-Auftritt.** Was fehlt, ist der
Marketing-Schritt: eine Textzeile je Bild und ein einheitlicher Hintergrund.
Der gehört vor den Bau abgenommen (Mockup-Regel).

⚠️ **Zwei Dinge zu klären, bevor der Satz hochgeht:**

1. **Fremde Fotos.** Die Fixture-Bilder in Album und Snap-Pins sind Aufnahmen
   aus Wikimedia Commons. Für Beweisbilder in Ordnung, für Store-Screenshots
   nicht: dort sind sie Werbematerial und tragen fremde Lizenzbedingungen
   (CC BY-SA verlangt Namensnennung). Auf `03_zugang.png` ist der Foto-Fächer
   am Spot-Pin hinter dem Blatt noch als Daumennagel zu sehen. Sauberste Lösung:
   drei eigene Fotos aufnehmen und die Fixtures damit ersetzen — dann sind auch
   Album- und Kamera-Bilder für den Store frei.
2. **Keine Aufnahme „ohne Netz".** Das stärkste Argument der Version lässt sich
   im Simulator nicht fotografieren (Netz kappen ohne Adresswechsel geht dort
   nicht). Entweder auf dem Gerät im Flugmodus aufnehmen — das steht ohnehin
   auf der Liste für den Geräte-Lauf — oder es bleibt bei `06_offline.png`, das
   die Zusage nur beschreibt.
