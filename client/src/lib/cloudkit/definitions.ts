/**
 * Plugin-Contract CloudKitSync — wörtlich aus docs/cloudkit-contract.md.
 *
 * Diese Datei ist die gemeinsame Fläche zwischen Swift-Plugin und TS-Layer:
 * Änderungen nur über den Contract, nie einseitig. Deshalb liegen hier NUR
 * Typen — keine Hilfsfunktionen, kein Default-Verhalten.
 */

export type CKAccountStatus =
  | "available" | "noAccount" | "restricted" | "couldNotDetermine" | "temporarilyUnavailable";

export interface CloudFriend {
  userID: string;          // CKRecord.ID.recordName des Gegenübers
  name: string;            // aus dessen Profile-Record; "" wenn (noch) keins da
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

  /** Legt Friendship-Zone + Share + eigenes Profile an. displayName = eigener Anzeigename. */
  createFriendInvite(opts: { displayName: string }): Promise<{ url: string }>;
  /** Akzeptiert eine beliebige Share-URL (Friend-Link). Schreibt bei Friendship-Shares das eigene Profile. */
  acceptShare(opts: { url: string; displayName: string }): Promise<void>;
  /** Aktualisiert den eigenen Profile-Record in allen Friendship-Zonen. */
  setDisplayName(opts: { name: string }): Promise<void>;

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

  /** CKDatabaseSubscriptions (private + shared, silent) anlegen + Remote-Push-Registrierung. Idempotent. */
  registerSubscriptions(): Promise<void>;

  addListener(eventName: "cloudChanged", listener: () => void): Promise<{ remove: () => Promise<void> }>;
}
