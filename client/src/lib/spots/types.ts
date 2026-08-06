/**
 * Community-Datenmodell (v2.2, docs/konzept-community-local-first.md).
 * Lokal-first: alles liegt auf dem Gerät; CloudKit ist die Transportschicht
 * darüber (lib/spots/sync.ts) — jede Antwort bleibt ein eigener Child-Record
 * (1 Record = 1 Schreiber).
 *
 * Die Cloud-Felder sind durchweg OPTIONAL: ein persistierter Eintrag aus einer
 * älteren App-Version muss ohne sie weiter parsen (Kaltstart), und ein Spot
 * ohne `zoneName` ist per Definition rein lokal (Schublade A).
 */

export interface Spot {
  id: string;
  name: string;
  emoji: string;
  lng: number;
  lat: number;
  createdAt: number;
  /** CloudKit-Zone `spot-<id>`; fehlt = nie geteilt, bleibt auf dem Gerät. */
  zoneName?: string;
  /** SELF_ID oder `userID` des Owners — nur gesetzt, solange der Spot geteilt ist. */
  ownerId?: string;
  /** Cloud-Wahrheit: akzeptierte Teilnehmer ohne mich. Vor der Cloud-Anlage: die gewählten Freunde. */
  participantIds?: string[];
  /** Share-URL des eigenen Spots — nötig, um ihn weiteren Freunden zuzustellen. */
  shareURL?: string;
  /** Cloud-Anlage steht noch aus (Outbox) — wird bei Netz/Resume nachgeholt. */
  sharePending?: boolean;
}

export interface Friend {
  id: string;
  name: string;
  /** Avatar-Farbe (CSS-Farbe), lokal vergeben. */
  color: string;
  /** Friendship-Zone `friend-<uuid>` — Zustellweg für Spot-Angebote. */
  friendshipZone?: string;
}

export type ReplyStatus = "in" | "out";

/** Antwort eines Eingeladenen — trägt den EIGENEN Zustand, nie einen Änderungsantrag. */
export interface Reply {
  participantId: string;
  status: ReplyStatus;
  /** Eigene Ankunftszeit (epoch ms) — gesetzt bei „Ich komme um …". */
  arrivalTime?: number;
}

export interface Invitation {
  id: string;
  spotId: string;
  /** "me" für lokal erstellte Einladungen; Fremd-IDs kommen erst mit CloudKit-Sync. */
  hostId: string;
  /** Anker-Zeit des Gastgebers (epoch ms) — „ab 20:00", kein Vertrag. */
  time: number;
  createdAt: number;
  cancelled: boolean;
  replies: Reply[];
}

export const SELF_ID = "me";

/** Anzeigename eines Freundes — ein noch leeres Profil ist ein Zustand, kein Fehler. */
export function friendLabel(friend: Friend): string {
  return friend.name.trim() || "Freund";
}

/** Einladung nach ihrem Zeitpunkt natürlich auslaufen lassen (Konzept: „Client blendet Vergangenes aus"). */
export const INVITATION_LINGER_MS = 2 * 60 * 60 * 1000;

export function invitationActive(inv: Invitation, now: number): boolean {
  return !inv.cancelled && now < inv.time + INVITATION_LINGER_MS;
}
