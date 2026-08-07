# CloudKit-Sync — technischer Contract (bindend für den Build)

Stand: 2026-08-06 · Ergänzt `konzept-community-local-first.md` (Produktregeln dort gelten unverändert).
Dieser Contract ist das Design-Gate zwischen Swift-Plugin (Builder A) und TS-Sync-Layer (Builder B):
beide bauen exakt gegen die hier definierte API. Abweichungen nur mit Begründung im Ergebnis-Report.

## Rahmen

- Container: `iCloud.de.leonvalentin.greenzones` · Team `KXJRXU59ZB` · Deployment-Target iOS 15 → **klassische CKOperations, KEIN CKSyncEngine** (iOS 17+).
- Kein Kontakte-Lookup, kein Nutzerverzeichnis: Shares mit `publicPermission = .readWrite` → Beitritt ausschließlich über Share-URL.
- Datenmengen sind winzig (Handvoll Spots/Freunde) → **Pull-Snapshot-Modell**: `fetchAll()` liefert immer den kompletten Zustand. Keine Change-Tokens, kein Delta-Sync in v1.
- Konzept-Doc-Korrektur (dort vermerken, wenn angefasst): `CKQuerySubscription` funktioniert NICHT in der
  sharedCloudDatabase. Stattdessen: **CKDatabaseSubscription (silent) auf private + shared DB** → App fetcht →
  erzeugt bei neuen Invitations/Replies eine **lokale** Notification mit korrektem Text.

## Zonen- und Record-Schema (1 Record = 1 Schreiber — Verfassungsregel)

Alle Custom-Zonen liegen in der privaten DB des jeweiligen Owners; Teilnehmer sehen sie über die shared DB.
**Zone-Sharing** (`CKShare(recordZoneID:)`, iOS 15+): der Share teilt die ganze Zone, keine parent-Referenzen nötig.
(Builder A: gegen aktuelle Apple-Doku via Context7 verifizieren; falls Zone-Sharing eine Falle hat, ist
hierarchisches Root-Record-Sharing der Fallback — dann parent-Referenzen auf den Root setzen und im Report begründen.)

### Friendship-Zone `friend-<uuid>` — pro Freundschaft eine Zone

| Record-Type | recordName | Felder | Schreiber |
|---|---|---|---|
| `Friendship` | `friendship` | `createdAt: Date` | Ersteller (einmalig) |
| `Profile` | `profile-<userRecordID-Name>` | `name: String`, `emoji: String` | NUR die jeweilige Person (jeder pflegt genau seinen) |
| `SpotOffer` | `offer-<spotZoneName>` | `spotShareURL: String`, `spotName: String`, `spotEmoji: String` | der Anbietende |

- Freundschaft entsteht: A ruft `createFriendInvite` → Zone + `Friendship` + eigenes `Profile` + Share → URL via System-Share-Sheet verschicken. B öffnet Link (oder `acceptShare`) → B schreibt sein `Profile`.
- **Freundesliste = Menge aller Friendship-Zonen** (eigene in private DB + akzeptierte in shared DB). Freund-Identität = `userRecordID` des Gegenübers (aus `CKShare.participants` bzw. `Profile`-creatorUserRecordID).
- `SpotOffer` ist der Transportkanal, um einem BESTEHENDEN Freund einen Spot-Share zuzustellen, ohne dass er manuell einen Link klickt: Empfänger-Gerät sieht den Offer (Push/Fetch) → akzeptiert die `spotShareURL` automatisch via `CKFetchShareMetadataOperation` + `CKAcceptSharesOperation` (idempotent — bereits akzeptiert = Erfolg).
- Freund entfernen: Teilnehmer aus dem Friendship-Share entfernen bzw. als Teilnehmer den Share verlassen (`CKDatabase.delete(withRecordZoneID:)` in shared DB entfernt die Teilnahme). Zusätzlich aus allen eigenen Spot-Shares entfernen.

### Spot-Zone `spot-<uuid>` — pro Spot eine Zone

| Record-Type | recordName | Felder | Schreiber |
|---|---|---|---|
| `Spot` | `spot` | `name: String`, `emoji: String`, `lng: Double`, `lat: Double`, `createdAt: Date` | Owner |
| `Invitation` | `<uuid>` (kommt aus TS) | `time: Date`, `createdAt: Date`, `cancelled: Int (0/1)` | der Host = Ersteller dieses Records (jeder Teilnehmer DARF einladen) |
| `Reply` | `reply-<invitationId>-<userRecordID-Name>` | `invitationId: String`, `status: String ("in"/"out")`, `arrivalTime: Date?` | NUR der jeweilige Teilnehmer (recordName macht Upsert pro Person natürlich) |

- `hostId` einer Invitation = `creatorUserRecordID` des Records (Systemfeld, fälschungssicher) — KEIN eigenes Feld.
- `participantId` einer Reply = `creatorUserRecordID`.
- Ein lokaler Spot ohne Share bleibt rein lokal (Schublade A) — CloudKit kommt erst bei „teilen" ins Spiel.
- Spot löschen (Owner): ganze Zone löschen. Spot verlassen (Teilnehmer): Zone aus shared DB entfernen.

## Plugin-API (TS-Definition — wörtlich so bauen)

Datei `client/src/lib/cloudkit/definitions.ts` (Builder B legt sie an; Builder A implementiert die
Swift-Seite methodengleich; Plugin-Name im `registerPlugin`-Aufruf: **`CloudKitSync`**):

```ts
export type CKAccountStatus =
  | "available" | "noAccount" | "restricted" | "couldNotDetermine" | "temporarilyUnavailable";

export interface CloudFriend {
  userID: string;          // CKRecord.ID.recordName des Gegenübers
  name: string;            // aus dessen Profile-Record; "" wenn (noch) keins da
  emoji: string;           // gewähltes Zeichen; "" = keins, dann trägt der Avatar die Initiale
  friendshipZone: string;  // Zonen-Name friend-<uuid>
  isOwner: boolean;        // true = ich habe die Freundschaft angelegt
}

export interface CloudSpot {
  zoneName: string;        // spot-<uuid>
  ownerUserID: string;     // "" wenn ich selbst Owner bin
  isMine: boolean;
  name: string; emoji: string; lng: number; lat: number; createdAt: number;
  participantUserIDs: string[];  // akzeptierte Teilnehmer ohne mich
  shareURL: string;        // nur gefüllt wenn isMine
}

export interface CloudReply { participantUserID: string; status: "in" | "out"; arrivalTime?: number; }

export interface CloudInvitation {
  id: string;              // recordName
  spotZone: string;
  hostUserID: string;      // creatorUserRecordID; eigener Record → eigene userID (Aufrufer mappt auf "me")
  time: number; createdAt: number; cancelled: boolean;
  replies: CloudReply[];
}

export interface CloudSnapshot {
  status: CKAccountStatus;
  userID: string;          // "" wenn status !== "available"
  friends: CloudFriend[];
  spots: CloudSpot[];
  invitations: CloudInvitation[];
}

export interface CloudKitSyncPlugin {
  getAccountStatus(): Promise<{ status: CKAccountStatus }>;
  /** Kompletter Zustand. Verarbeitet dabei offene SpotOffers (Auto-Accept, idempotent). */
  fetchAll(): Promise<CloudSnapshot>;

  /** Legt Friendship-Zone + Share + eigenes Profile an. Profil = eigener Anzeigename + Zeichen. */
  createFriendInvite(opts: { displayName: string; emoji: string }): Promise<{ url: string }>;
  /** Akzeptiert eine beliebige Share-URL (Friend-Link). Schreibt bei Friendship-Shares das eigene Profile. */
  acceptShare(opts: { url: string; displayName: string; emoji: string }): Promise<void>;
  /** Aktualisiert den eigenen Profile-Record in allen Friendship-Zonen. Leeres emoji löscht das Zeichen. */
  setProfile(opts: { name: string; emoji: string }): Promise<void>;

  /** Legt Spot-Zone + Spot-Record + Share an. id = lokale Spot-UUID (wird Teil des Zonen-Namens spot-<id>). */
  createSpotShare(opts: { id: string; name: string; emoji: string; lng: number; lat: number; createdAt: number }):
    Promise<{ zoneName: string; shareURL: string }>;
  /** Stellt den Spot-Share bestehenden Freunden zu (SpotOffer in deren Friendship-Zonen). */
  offerSpotToFriends(opts: { zoneName: string; shareURL: string; spotName: string; spotEmoji: string;
    friendshipZones: string[] }): Promise<void>;
  /** Owner: Zone löschen. Teilnehmer: Teilnahme beenden. Plugin unterscheidet selbst. */
  deleteSpot(opts: { zoneName: string }): Promise<void>;

  /** Upsert Invitation (create, Zeit ändern, absagen — cancelled=true). Nur eigene Records. */
  saveInvitation(opts: { spotZone: string; id: string; time: number; createdAt: number; cancelled: boolean }):
    Promise<void>;
  /** Upsert der EIGENEN Reply zu einer Invitation. */
  saveReply(opts: { spotZone: string; invitationId: string; status: "in" | "out"; arrivalTime?: number }):
    Promise<void>;

  /** CKDatabaseSubscriptions (private + shared, sichtbar + mutable-content) anlegen + Remote-Push-Registrierung. Idempotent. */
  registerSubscriptions(): Promise<void>;

  /**
   * Fragt einmalig nach der Mitteilungs-Erlaubnis (System-Dialog). Der Systemstatus ist
   * der Zustand: schon entschieden → kein Dialog, nur der aktuelle Wert. Nie ein Reject.
   */
  ensureNotificationPermission(): Promise<{ granted: boolean }>;

  addListener(eventName: "cloudChanged", listener: () => void): Promise<{ remove: () => Promise<void> }>;
}
```

### Fehler-Semantik

- Jede Methode rejected mit `code` aus: `"noAccount" | "network" | "notFound" | "conflict" | "internal"`
  (Capacitor `reject(message, code)`). TS-Seite mappt auf Nutzertext — **blameless wording**, Netz/Account
  benennen, nie den Nutzer.
- `fetchAll` bei `status !== available`: **kein Reject** — Snapshot mit leeren Listen und dem Status. Kein
  Account ist ein DEFINIERTER Zustand, kein Fehler.
- Offline-Regeln (Konzept): Spot-Share-Anlage darf nachgeholt werden (Outbox im TS-Layer); Invitation/Reply
  bei `network`-Fehler = ehrlicher Abbruch mit Meldung, KEIN stilles Nachliefern.

### Events & App-Lebenszyklus

- `cloudChanged` feuert bei: Remote-Push (CKDatabaseNotification), erfolgreichem Share-Accept von außen
  (Universal Link → `userDidAcceptCloudKitShareWith` in Scene- UND AppDelegate-Variante).
- TS-Layer refetcht bei: App-Start (nach Store-`ready`), `appStateChange → active` (@capacitor/app),
  `cloudChanged`.
- Sichtbare Pushes (seit Subscription v2 `gz-*-db-v2`): die Subscription trägt einen neutralen
  `alertBody` als Fallback + `mutable-content`; die App-Extension `NotificationService` fetcht die
  gz-Zonen der betroffenen DB und ersetzt den Text durch das konkrete Ereignis (Invitation >
  SpotOffer > Reply > neues Profile; alles andere → `interruptionLevel .passive`). Frisch = jünger
  als 30 min UND letzter Schreiber ≠ ich. Die v1-IDs (silent-only) räumt `registerSubscriptions`
  beim nächsten Lauf ab. Der TS-Layer erzeugt weiterhin KEINE lokalen Notifications.
- Mitteilungs-Erlaubnis: TS-Layer ruft `ensureNotificationPermission` nach jedem Merge mit
  mindestens einem Freund — der System-Dialog erscheint genau einmal (Status `notDetermined`),
  danach ist der Systemstatus die Wahrheit. Ohne Erlaubnis läuft alles weiter, nur bannerlos.

## iOS-Projekt-Anforderungen (Builder A)

- Entitlements `App/App.entitlements`: `com.apple.developer.icloud-services = [CloudKit]`,
  `com.apple.developer.icloud-container-identifiers = [iCloud.de.leonvalentin.greenzones]`,
  `aps-environment = development`. In pbxproj `CODE_SIGN_ENTITLEMENTS` verdrahten.
- Info.plist: `CKSharingSupported = YES`; Background-Mode `remote-notification`.
- Plugin-Registrierung Capacitor 8 + SPM (Custom Code im App-Target): eigene
  `CAPBridgeViewController`-Subclass mit `capacitorDidLoad()` → `bridge?.registerPluginInstance(...)`,
  Storyboard-CustomClass umstellen. Gegen Capacitor-8-Doku (Context7) verifizieren.
- Push: `UIApplication.registerForRemoteNotifications` + `didReceiveRemoteNotification` →
  `CKNotification`-Parse → Event. Sim empfängt keine echten APNs — Pfad muss über `simctl push` testbar sein.
- Signing Sim-Build braucht kein Profil; Container-Registrierung im Portal ggf. via
  `xcodebuild -allowProvisioningUpdates` versuchen — scheitert das headless, NICHT blockieren:
  dokumentieren, Leon erledigt es in Xcode (2 min). Alle CloudKit-Calls müssen bis dahin sauber
  mit `noAccount`/`internal` failen, nie crashen.

## TS-Layer-Regeln (Builder B)

- Web-/Dev-Stub: `getAccountStatus → "couldNotDetermine"`, `fetchAll` → leerer Snapshot, Writes rejecten
  mit `noAccount`. Definierter „nicht verfügbar"-Zustand — KEIN Fake-Erfolg, kein Mock-Sync.
- Merge-Regel: Für geteilte Zonen ist der Cloud-Snapshot die Wahrheit (ersetzt lokale Kopie der Fremd-Daten);
  rein lokale Spots/Invitations (ohne zoneName) bleiben unberührt. Merge idempotent — zweimal derselbe
  Snapshot = null Mutationen (Snapshot-Stabilität der Stores respektieren, `useSyncExternalStore`).
- Typen-Erweiterung NUR mit optionalen Feldern (`Spot.zoneName?`, `Spot.ownerId?`,
  `Spot.participantIds?`, `Friend.friendshipZone?` …) — persistierte Alteinträge müssen weiter parsen
  (Kaltstart-Test!). `Friend.id` = `userID` aus CloudKit; `SELF_ID = "me"` bleibt für die eigene Person.
- `FriendStore` bekommt den Schreibpfad, den bisher niemand hatte (Sync ist jetzt die Quelle).
- Einladungs-CTA und Freunde-Chips werden mit echten Daten lebendig; Reply/Manage-Sheets hängen an echten
  Teilnehmern statt Fixtures. Mockups `mockup/community.html` + `mockup/invite.html` bleiben bindend fürs UI.
- NoAccount-/Offline-States im UI: ruhiger Hinweis („Für Freunde & geteilte Spots bei iCloud anmelden —
  Einstellungen → [dein Name]"), App bleibt voll lokal nutzbar. Kein Modal-Zwang, kein Dauer-Banner.
