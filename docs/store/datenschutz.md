# Datenschutzerklärung — GreenZones

Stand: 18. August 2026

Diese Erklärung beschreibt, was die iOS-App **GreenZones** mit Daten tut. Sie
ist am Code erhoben und deckt sich Zeile für Zeile mit der internen
Datenlandkarte (`docs/datenlandkarte.md`).

⚠️ **Vor der Veröffentlichung auszufüllen:** Name und ladungsfähige Anschrift
des Verantwortlichen sowie eine Kontaktadresse. Ohne diese Angaben ist die
Erklärung nach Art. 13 DSGVO unvollständig. Die Stellen sind mit `[…]`
markiert.

---

## 1. Verantwortlicher

```
[Vor- und Nachname]
[Straße und Hausnummer]
[PLZ und Ort]
Deutschland
E-Mail: [kontakt@…]
```

Eine Datenschutzbeauftragte oder einen Datenschutzbeauftragten gibt es nicht;
die Voraussetzungen dafür liegen nicht vor.

## 2. Das Wichtigste zuerst

**GreenZones hat keinen eigenen Server.** Es gibt kein Nutzerkonto, keine
Anmeldung, keine Werbung und keine Analyse. Alles, was Sie in der App anlegen,
liegt auf Ihrem Gerät und — sobald Sie etwas mit anderen teilen — in Ihrer
eigenen iCloud. Der Anbieter dieser App hat darauf **keinen Zugriff** und kann
sich keinen verschaffen.

## 3. Daten auf Ihrem Gerät

Diese Daten verlassen Ihr Gerät nur, wenn Sie etwas teilen (Abschnitt 4):

- **Zuletzt gesuchte Ziele** (die fünf zuletzt gewählten): Name, Beschreibung,
  Koordinate, Zeitpunkt. Löschbar in der App unter „Über GreenZones" →
  „Karte & Daten verwalten" → „Zuletzt gesucht löschen".
- **Spots**: Name, Zeichen, Koordinate, Zeitpunkt, Zonenstatus.
- **Freunde**: der Name, den die jeweilige Person selbst eingetragen hat, dazu
  Zeichen und Farbe.
- **Termine und Antworten**: Zeitpunkt eines Treffens, Zu- und Absagen mit der
  jeweils angekündigten Ankunftszeit.
- **Bilder (Snaps)**: die Bilddatei sowie Aufnahmezeit, Aufnahmeort und
  gewählte Sichtbarkeit als Angaben in der Datenbank.
- **Einstellungen**: Ihr Anzeigename, Ihr Zeichen und Vermerke darüber, welche
  Hinweise Ihnen bereits gezeigt wurden.

**In den Bilddateien selbst stehen keine Metadaten** — kein Ort, kein
Aufnahmezeitpunkt, keine Gerätekennung. Die Drehung ist in die Bildpunkte
eingerechnet.

**Ihr laufender Standort wird nicht gespeichert.** Er wird nur verwendet, um
Ihnen anzuzeigen, in welcher Zone Sie gerade stehen, und um die Karte zu
zentrieren.

Wenn Sie die App löschen, werden alle diese Daten auf dem Gerät mit gelöscht.

## 4. Daten, die Ihr Gerät verlassen

### 4.1 Apple iCloud (CloudKit)

Sobald Sie einen Freund einladen, einen Spot teilen, zu einem Termin einladen
oder ein Bild aufnehmen, werden die betreffenden Angaben in Ihre **private
bzw. geteilte iCloud-Datenbank** geschrieben. Beteiligte Freunde können lesen,
was Sie ihnen freigegeben haben — sonst niemand. Eine öffentliche
CloudKit-Datenbank wird nicht verwendet.

Übertragen werden dabei: Name und Zeichen Ihres Profils, Spotname, Zeichen und
**Koordinate des Spots**, Termine und Antworten, sowie Bilder samt
**Aufnahmekoordinate**. Ihre laufende Position wird nie übertragen — dafür
existiert kein Feld.

Als Kennung dient ausschließlich die CloudKit-Nutzerkennung, die Apple je
Container vergibt. Weder Ihr iCloud-Name noch Apple-ID, E-Mail-Adresse oder
Telefonnummer werden ausgelesen. Der angezeigte Name ist der, den Sie selbst
eingetragen haben.

Rechtsgrundlage: Art. 6 Abs. 1 lit. b DSGVO — ohne diese Übertragung gibt es
die gemeinsamen Funktionen nicht. Verantwortlich für den iCloud-Dienst ist die
Apple Inc. bzw. Apple Distribution International; es gelten deren
Datenschutzbestimmungen.

### 4.2 Kartenbild — `tiles.openfreemap.org`

Das Kartenbild (Straßen, Namen, Flächen) wird beim Betrachten geladen. Dabei
erfährt der Betreiber, **welchen Kartenausschnitt** Sie ansehen, sowie Ihre
IP-Adresse. Betreiber ist OpenFreeMap, nicht GreenZones.

Wenn Sie in der App „Umgebung sichern" antippen, wird ein Gebiet einmalig
heruntergeladen; danach lädt die Karte in diesem Gebiet nichts mehr nach.
Rechtsgrundlage: Art. 6 Abs. 1 lit. f DSGVO (Darstellung der Karte).

### 4.3 Adresssuche — `photon.komoot.io`

Nur wenn Sie ausdrücklich „Nach Adressen suchen" antippen oder die Eingabetaste
drücken, wird Ihr **Suchbegriff** an den Dienst Photon der Komoot GmbH
gesendet, zusammen mit einer festen Deutschland-Begrenzung und Ihrer
IP-Adresse. **Ihre Position wird dabei nicht mitgesendet.** Tippen allein löst
keine Anfrage aus. Die Suche nach Orten (Parks, Seen, Plätzen, Bahnhöfen)
funktioniert vollständig auf dem Gerät und erreicht keinen Dienst.
Rechtsgrundlage: Art. 6 Abs. 1 lit. b DSGVO.

### 4.4 Mitteilungen

Wenn Sie Mitteilungen erlauben, werden Push-Nachrichten über Apple zugestellt.
Der Text wird auf Ihrem Gerät erzeugt: die Erweiterung liest die Änderung aus
Ihrer iCloud und formuliert den Hinweis lokal. Der Anbieter der App erfährt
davon nichts.

## 5. Was nicht stattfindet

Kein Tracking, keine Werbekennung, kein Analysedienst, kein Absturzmelder, kein
Profiling, keine automatisierte Entscheidungsfindung, keine Weitergabe an
Dritte zu Werbezwecken. Es werden nur zwei fremde Programmbibliotheken
verwendet (MapLibre für die Karte, GRDB für die lokale Datenbank); beide
übertragen von sich aus nichts.

## 6. Ihre Rechte

Sie haben das Recht auf Auskunft (Art. 15), Berichtigung (Art. 16), Löschung
(Art. 17), Einschränkung (Art. 18), Datenübertragbarkeit (Art. 20) und
Widerspruch (Art. 21) sowie das Recht, sich bei einer Aufsichtsbehörde zu
beschweren (Art. 77).

Praktisch gilt: Der Anbieter speichert nichts über Sie und kann deshalb weder
Auskunft über Inhalte geben noch Inhalte löschen. **Die Kontrolle liegt bei
Ihnen:**

- Einzelne Bilder: im Betrachter dauerhaft löschen oder ausblenden.
- Spots und Freundschaften: in der App entfernen; damit endet der gemeinsame
  Zugriff für beide Seiten.
- Suchverlauf: „Über GreenZones" → „Karte & Daten verwalten" → „Zuletzt gesucht
  löschen".
- Alles: die App löschen. Damit sind die lokalen Daten weg. In der iCloud
  verbleibende Freigaben können Sie in den iCloud-Einstellungen Ihres Geräts
  verwalten.

Für Daten, die Apple im Rahmen von iCloud verarbeitet, wenden Sie sich an
Apple; für die Kartenkacheln an OpenFreeMap, für die Adresssuche an die Komoot
GmbH.

## 7. Kinder

Die App richtet sich an Erwachsene und ist im App Store entsprechend
eingestuft. Sie ist nicht für Kinder bestimmt.

## 8. Änderungen

Ändert sich etwas an der Verarbeitung, wird diese Erklärung angepasst; das
Datum oben zeigt den Stand. Die jeweils geltende Fassung ist über den Link im
App Store und in der App erreichbar.

---

## Rechtliches zur Karte

Zonen berechnet aus © OpenStreetMap-Daten (ODbL). Kartenbild: OpenFreeMap ·
© OpenMapTiles. Die Zonen sind als 100-Meter-Umkreis um die gesamte Fläche der
Schutzobjekte berechnet — im Zweifel großzügiger als das Gesetz. GreenZones ist
eine Orientierungshilfe ohne Gewähr auf Richtigkeit oder Vollständigkeit und
ersetzt keine Rechtsberatung.
