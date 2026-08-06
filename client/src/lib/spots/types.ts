/**
 * Community-Datenmodell (v2.2, docs/konzept-community-local-first.md).
 * Lokal-first: alles liegt auf dem Gerät; CloudKit-Sync kommt als eigene
 * Transportschicht (Plugin-Spike), das Modell hier ändert sich dadurch nicht —
 * im Sync-Fall wird jede Antwort ein eigener Child-Record (1 Record = 1 Schreiber).
 */

export interface Spot {
  id: string;
  name: string;
  emoji: string;
  lng: number;
  lat: number;
  createdAt: number;
}

export interface Friend {
  id: string;
  name: string;
  /** Avatar-Farbe (CSS-Farbe), lokal vergeben. */
  color: string;
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

/** Einladung nach ihrem Zeitpunkt natürlich auslaufen lassen (Konzept: „Client blendet Vergangenes aus"). */
export const INVITATION_LINGER_MS = 2 * 60 * 60 * 1000;

export function invitationActive(inv: Invitation, now: number): boolean {
  return !inv.cancelled && now < inv.time + INVITATION_LINGER_MS;
}
