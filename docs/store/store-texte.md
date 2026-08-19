# Store-Angaben GreenZones 2.0

Stand 19.08.2026. Gilt für App-ID **6798829082**, `MARKETING_VERSION 2.0`,
`CURRENT_PROJECT_VERSION 4`.

Alle Texte hängen an `docs/datenlandkarte.md` — wer dort etwas ändert, ändert
hier mit. Und sie sind **konsumneutral** formuliert (App Store Review 1.4.3):
die App beschreibt, wo das Gesetz Grenzen zieht, sie fordert zu nichts auf,
bewirbt nichts und nennt keine Bezugsquellen.

✅ **Am 19.08. in App Store Connect eingetragen** (Web-UI; die API darf keine
App-Infos anlegen) und nach einem Neuladen der Seite feldweise gegengelesen:
Name, Untertitel, Kategorien, Beschreibung, Werbetext, Schlüsselwörter,
Support-URL, Version 2.0, Copyright, Review-Anmerkungen samt Kontakt,
Datenschutz-URL, Altersfreigabe, Inhaltsrechte, Preis und Verfügbarkeit.

Offen bleiben nur die **Screenshots** (siehe unten) und der **Build**.

⚠️ **Nicht von mir gemacht, weil es Leon selbst tun muss:** App Store Connect
meldet auf der Apps-Übersicht eine aktualisierte Lizenzvereinbarung des Apple
Developer Program. Bis der Accountinhaber sie im Bereich „Verträge" annimmt,
lässt sich keine Version zur Prüfung übermitteln.

---

## Kurzfelder

| Feld | Inhalt | Länge |
|---|---|---|
| **Name** | `GreenZones` | 10 / 30 |
| **Untertitel** | `Wo §5 KCanG Grenzen zieht` | 25 / 30 |
| **Werbetext** (jederzeit änderbar) | `Neu: Karte auch ohne Netz, Spots mit Freunden, Bilder im eigenen Kreis.` | 71 / 170 |
| **Keywords** | `KCanG,Cannabisgesetz,Konsumverbot,Schutzzone,Karte,Abstand,100 Meter,Fußgängerzone,Recht,Offline` | 98 / 100 |
| **Primäre Kategorie** | Referenz (in der deutschen UI: „Nachschlagewerke") | — |
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
• Rote Flächen: 100 m um Schulen, Kitas, Spielplätze, Jugendtreffs und Sportstätten.
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
Shots entstehen live in der App, nie aus der Mediathek. Sie landen am Spot in
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
• Shots: live aufgenommen, sichtbar nur im gewählten Kreis, ohne Ort in der Datei.
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

**Eingetragen 19.08. — mit einer Abweichung, die Leon entschieden hat.** Apples
Fragebogen ist inzwischen siebenstufig und kennt kein 17+ mehr; aus den Antworten
(nur „Drogenverweise: selten", alles andere „nie") rechnet er **13+**. Leon hat
auf **18+ überschrieben** — das ist die nächste Stufe über 16+ und entspricht der
Linie von 17+: KCanG gilt für Erwachsene, und ein Rückläufer wegen Richtlinie
1.4.3 kostet mehr als die höhere Grenze. Gilt in 173 Ländern.

Die übrigen Antworten, weil zwei davon streitbar sind:

| Frage | Antwort | Warum |
|---|---|---|
| Benutzergenerierte Inhalte | **ja** | Shots sind vom Nutzer erstellt und Kern der App. Apples Definition nennt „weite Verbreitung", die hier fehlt — „ja" ist trotzdem die konservative Antwort und deckt sich mit den Review-Notes zu 1.2. |
| Soziale Medien | **nein** | Die Definition verlangt Feed oder Entdecken-Funktion, „sichtbar an viele". Beides gibt es nicht: Freundschaft entsteht nur über einen persönlich verschickten Link. |
| Uneingeschränkter Internetzugriff, Nachrichten/Chat, Werbung, Kindersicherung, Altersnachweis | nein | — |
| alle Inhaltsfragen außer Drogen | nie | — |

**Inhaltsrechte: „Ja, mit den erforderlichen Rechten."** Die App zeigt fremde
Inhalte — OpenStreetMap-Daten und das Kartenbild von OpenFreeMap. Beides ist
lizenziert und wird in der App und im Store genannt.

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

**Neu aufgenommen am 19.08.** (nach der Zonen-Erweiterung und der Verlegung der
Fixture-Orte aus dem Maschsee), Simulator iPhone 17 Pro Max
`910999EE-5AC2-43F3-815D-5CAFE7B77C33`, 1320 x 2868 nachgemessen, Statusleiste
per `simctl status_bar override --time 9:41`. Sie liegen in `ios/shots/store/`
(gitignoriert, überleben aber die Sitzung):

| Datei | Zeigt |
|---|---|
| `01_karte.png` | Karte mit Zonen, Standort, Statuszeile „Hier erlaubt · Verbotszone 104 m" |
| `02_suche.png` | Suche „masch" mit sechs Ortstreffern und Entfernungen |
| `03_zugang.png` | „Wer sieht ,Unsere Bank‘?" — Zugang als Auswahl |
| `04_termin.png` | Einladen mit Zeitband, „Nur die Angehakten bekommen Bescheid" |
| `05_daten.png` | Onboarding „Deine Daten bleiben deine" |
| `06_offline.png` | „Karte & Daten" mit „Umgebung sichern (20 km, ca. 70 MB)" |

### Der Store-Auftritt — gebaut, abgenommen, hochgeladen

`ios/Scripts/store_frames.py` macht daraus die Store-Bilder: **direkt in
1320 × 2868 gezeichnet**, nicht hochskaliert, damit die Schrift scharf bleibt.
Bild 1 als Vollbild mit dunkler Textfläche darunter, die übrigen hell mit
Textzeile oben. Ein Lauf dauert zwei Sekunden.

Die **Statusleiste wird in beiden Auftritten abgeschnitten** (205 px). Damit ist
auch das Kartenlabel „ALTSTADT" weg, das sich in fünf von sechs Aufnahmen hinter
die Uhrzeit schob — abschneiden löst es, ein Rahmen hätte es nur verdeckt. Den
Fixture-Standort dafür zu verschieben wäre der falsche Weg gewesen: seine Lage
ist gegen Wasserfläche, Gebäude und Zonen gemessen.

Leon-Abnahme 19.08. über das Artifact
`77bf43eb-e432-4cc1-b447-3b4dfb3e7976` („Passt, hochladen").

**Hochgeladen** ins Set `APP_IPHONE_67` (de-DE). Die Weboberfläche taugt dafür
schlecht: mehrere Dateien auf einmal landen in beliebiger Reihenfolge, und
sortieren geht nur per Drag. Deshalb `ios/Scripts/asc_screenshots.mjs` —
dort ist die Reihenfolge ein eigener Aufruf.

**Eigene Fotos statt Wikimedia — erledigt 19.08.** Leon hat vier Aufnahmen
geliefert; drei davon sind verwendbar (die vierte war ein Screenshot). Daraus
wurden die vier Fixtures in 3:4 zugeschnitten:

| Fixture | Aufnahme |
|---|---|
| `snap1.jpg` | Abendlicht über der Stadt, Park und Fluss |
| `snap2.jpg` | Balkonmauer mit Tee und Tulpen, Stadt dahinter |
| `snap3.jpg` | Capitol bei Nacht, blaue Leuchtschrift |
| `snap4.jpg` | enger Ausschnitt derselben Abendaufnahme: Steg am Wasser |

⚠️ **Beim Zuschneiden wurden die Metadaten entfernt.** Die Originale trugen
GPS-Koordinaten (52°22′ N, 9°43′ E) — die Wohnung des Fotografen. Wer die
Fixtures künftig austauscht, muss das ebenso tun: die Kamera-Pipeline der App
streift GPS ab, die Dateien im Repo laufen nicht durch sie hindurch.

⚠️ **Weiter offen: keine Aufnahme „ohne Netz".** Das stärkste Argument der
Version lässt sich im Simulator nicht fotografieren (Netz kappen ohne
Adresswechsel geht dort nicht). Entweder auf dem Gerät im Flugmodus aufnehmen —
das steht ohnehin auf der Liste für den Geräte-Lauf — oder es bleibt bei
`06_offline.png`, das die Zusage nur beschreibt.
