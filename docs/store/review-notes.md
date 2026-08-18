# Review-Notes GreenZones 2.0

Text für das Feld „Notes" der Version in App Store Connect. Er beantwortet
vorweg die drei Fragen, an denen diese App im Review sonst hängenbleibt:
Warum sieht der Prüfer leere Listen, warum gibt es keinen Melden-Knopf, und
warum steht bei den Datenschutzangaben „Keine Daten erfasst".

⚠️ Nicht eingetragen. Eintragen erst auf Leons Wort.

---

## Fassung Deutsch

```
Hallo,

drei Hinweise, die das Prüfen erleichtern:

1) KEIN LOGIN, ABER ICLOUD NÖTIG
Die App hat weder Konto noch Anmeldung. Karte, Zonenanzeige und Ortssuche
funktionieren sofort und ohne alles.
Die geteilten Funktionen (Spots, Freunde, Einladungen, Bilder) laufen
ausschließlich über CloudKit im iCloud-Konto des jeweiligen Nutzers. Auf einem
Gerät ohne angemeldete Apple-ID bleiben diese Listen leer und die App zeigt an
dieser Stelle einen Hinweis darauf — das ist kein Fehler.
Zum Prüfen genügt es, im Simulator oder auf dem Gerät mit einer beliebigen
Apple-ID in iCloud angemeldet zu sein. Ein Demo-Zugang von uns ist nicht
möglich, weil es keinen Server und keine Konten gibt.

2) NUTZERINHALTE (Richtlinie 1.2)
Bilder („Shots") sind ausschließlich in einem geschlossenen Kreis sichtbar:
Freundschaften entstehen nur über einen persönlich verschickten Einladungslink.
Es gibt keinen öffentlichen Feed, keine Suche nach Personen, keine Vorschläge
und keine Möglichkeit, Fremde oder deren Inhalte zu entdecken. Der Aufbau
entspricht damit einem geteilten Fotoalbum unter Bekannten.
Vorhanden sind: Bilder dauerhaft ausblenden, Personen aus einem Spot entfernen
und Freundschaften beenden (der Zugriff auf gemeinsame Inhalte endet damit
beidseitig). Ein Meldeweg an uns würde ins Leere laufen: ohne Server gibt es
keine Stelle, die Inhalte einsehen oder moderieren könnte — die Daten liegen in
den iCloud-Konten der Beteiligten.
Sollte die Prüfung hier dennoch etwas verlangen, setzen wir es um.

3) DATENSCHUTZANGABE „KEINE DATEN ERFASST"
Es gibt keinen Server und keinen Anbieter-Zugriff. Alle persönlichen Daten
liegen auf dem Gerät (SQLite, Dateien) und in der privaten bzw. geteilten
CloudKit-Datenbank des Nutzers; eine öffentliche CloudKit-Datenbank wird nicht
verwendet. Wir können weder Inhalte noch Nutzerkennungen einsehen.
Nach außen sprechen genau drei Stellen: Apple iCloud, tiles.openfreemap.org
(Kartenbild) und photon.komoot.io (Adresssuche, nur auf ausdrückliche Eingabe).
Kein Tracking, keine Werbe-ID, keine Analyse-Bibliothek.

INHALTLICH
Die App ist eine Karte zum deutschen Konsumcannabisgesetz (§5 Abs. 2 KCanG).
Sie zeigt, wo öffentlicher Konsum verboten ist — 100 m um Schulen, Kitas,
Spielplätze, Jugendtreffs und Sportstätten, dazu Fußgängerzonen zwischen 7 und
20 Uhr. Sie fordert zu keinem Konsum auf, bewirbt nichts, verkauft nichts und
nennt keine Bezugsquellen. In der App steht ausdrücklich, dass es sich um eine
Orientierungshilfe ohne Gewähr handelt und nicht um Rechtsberatung.

Vielen Dank fürs Prüfen.
```

---

## Fassung Englisch (falls das Team englisch prüft)

```
Hi,

three notes to make review easier:

1) NO LOGIN, BUT ICLOUD REQUIRED
There is no account and no sign-in. Map, zone status and place search work
immediately.
The shared features (spots, friends, invitations, photos) run entirely on
CloudKit inside each user's own iCloud account. On a device without an Apple ID
signed into iCloud, those lists stay empty and the app says so — this is not a
bug. Signing into iCloud with any Apple ID is enough to review them. We cannot
provide a demo account because there is no server and no accounts.

2) USER-GENERATED CONTENT (Guideline 1.2)
Photos ("shots") are visible only within a closed circle: friendships are
created solely through a personally shared invitation link. There is no public
feed, no people search, no suggestions, and no way to discover strangers or
their content — comparable to a shared photo album among acquaintances.
Available actions: hide a photo permanently, remove a person from a spot, and
end a friendship (which mutually ends access to shared content). A report
channel to us would go nowhere: without a server there is no party able to view
or moderate content — the data lives in the participants' iCloud accounts.
If review still requires one, we will add it.

3) PRIVACY LABEL "DATA NOT COLLECTED"
There is no server and no provider access. All personal data stays on device
(SQLite, files) and in the user's private or shared CloudKit database; no public
CloudKit database is used. We can see neither content nor user identifiers.
The app talks to exactly three external endpoints: Apple iCloud,
tiles.openfreemap.org (map imagery) and photon.komoot.io (address search, only
on explicit request). No tracking, no advertising identifier, no analytics SDK.

ABOUT THE CONTENT
The app is a map for the German Cannabis Act (§5 (2) KCanG). It shows where
public consumption is prohibited — within 100 m of schools, day-care centres,
playgrounds, youth centres and sports facilities, plus pedestrian zones between
7 am and 8 pm.
It does not encourage consumption, advertise, sell, or point to any source of
supply. The app states in plain words that it is guidance without warranty and
not legal advice.

Thanks for reviewing.
```

---

## Wenn es doch einen Rückläufer gibt

**Fall „1.2 verlangt einen Meldeweg".** Der Dialog steht bereits: im Betrachter
sitzt neben dem Papierkorb das durchgestrichene Auge mit „Bild ausblenden?" →
„Ausblenden" / „Ausblenden und <Name> entfernen". Ein „Melden" daneben ist eine
halbe Stunde Arbeit — der Record-Typ und der Schreibweg wurden am 18.08. bewusst
entfernt (`e08882b`), die Stelle ist bekannt. Dann aber ehrlich: ein Meldeweg
ohne Empfänger ist eine Attrappe. Besser wäre eine Mailadresse, an die der Text
samt Zeitpunkt geht — dann gibt es eine Stelle, die antwortet.

**Fall „1.4.3 / Drogenbezug".** Argumentationslinie: Gegenstand ist der
räumliche Geltungsbereich eines Gesetzes, nicht der Konsum. Vergleichbar mit
Apps zu Parkverbotszonen oder Drohnen-Sperrgebieten. Die App nennt keine
Bezugsquellen, zeigt keinen Konsum und wirbt nicht.

**Fall „Kartendaten/Lizenz".** Die ODbL-Nennung steht im ersten Info-Blatt
(„Zonen aus © OpenStreetMap-Daten (ODbL) · Karte: OpenFreeMap"), der vollständige
Lizenztext eine Ebene tiefer unter „Karte & Daten".
