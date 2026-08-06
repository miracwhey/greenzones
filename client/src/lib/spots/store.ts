/**
 * Lokale Datenschicht für Spots · Freunde · Einladungen (Konzept v2.2).
 *
 * Local-first: Wahrheit liegt auf dem Gerät (Capacitor Preferences), CloudKit
 * kommt später als eigene Transportschicht darüber — das Modell hier ändert
 * sich dadurch nicht.
 *
 * Zwei Invarianten, an denen die UI hängt:
 *  1. Snapshot-Stabilität: getSpots()/getInvitations()/getFriends() liefern
 *     dieselbe Array-Referenz, bis eine Mutation tatsächlich etwas ändert
 *     (useSyncExternalStore vergleicht per Identität — eine frische Kopie pro
 *     Aufruf wäre eine Endlosschleife).
 *  2. Schreiber laufen seriell hinter der initialen Ladung. Zwei parallele
 *     Preferences.set() würden sonst denselben Ausgangsstand serialisieren und
 *     der letzte gewinnt (Lost Update).
 */
import { Preferences } from "@capacitor/preferences";
import type { Friend, Invitation, Reply, Spot } from "./types";
import { invitationActive, SELF_ID } from "./types";

export const SPOTS_KEY = "gz_spots";
export const INVITES_KEY = "gz_invites";
export const FRIENDS_KEY = "gz_friends";

/** Prüft/normalisiert einen persistierten Eintrag; null = Eintrag verwerfen. */
type Parse<T> = (value: unknown) => T | null;

function record(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : null;
}

function parseSpot(value: unknown): Spot | null {
  const r = record(value);
  if (!r) return null;
  return typeof r.id === "string" &&
    typeof r.name === "string" &&
    typeof r.emoji === "string" &&
    typeof r.lng === "number" &&
    typeof r.lat === "number" &&
    typeof r.createdAt === "number"
    ? (value as Spot)
    : null;
}

function parseFriend(value: unknown): Friend | null {
  const r = record(value);
  if (!r) return null;
  return typeof r.id === "string" && typeof r.name === "string" && typeof r.color === "string"
    ? (value as Friend)
    : null;
}

function parseReply(value: unknown): Reply | null {
  const r = record(value);
  if (!r) return null;
  if (typeof r.participantId !== "string") return null;
  if (r.status !== "in" && r.status !== "out") return null;
  if (r.arrivalTime !== undefined && typeof r.arrivalTime !== "number") return null;
  return value as Reply;
}

function parseInvitation(value: unknown): Invitation | null {
  const r = record(value);
  if (!r) return null;
  if (
    typeof r.id !== "string" ||
    typeof r.spotId !== "string" ||
    typeof r.time !== "number" ||
    typeof r.createdAt !== "number" ||
    typeof r.cancelled !== "boolean" ||
    !Array.isArray(r.replies)
  ) {
    return null;
  }
  // Eine kaputte Antwort darf nicht die ganze Einladung (= den Anker des
  // Gastgebers) mitnehmen — nur die Antwort fällt raus.
  const replies: Reply[] = [];
  for (const raw of r.replies) {
    const reply = parseReply(raw);
    if (reply) replies.push(reply);
  }
  return replies.length === r.replies.length
    ? (value as Invitation)
    : ({ ...(value as Invitation), replies } satisfies Invitation);
}

function parseList<T>(raw: string | null, parse: Parse<T>): T[] {
  if (!raw) return [];
  // Korrupter Storage ist ein DEFINIERTES Ergebnis (leerer Bestand), kein
  // Crash beim Kaltstart — die App muss auch mit zerschossener Datei starten.
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return [];
  }
  if (!Array.isArray(parsed)) return [];
  const items: T[] = [];
  for (const entry of parsed) {
    const item = parse(entry);
    if (item) items.push(item);
  }
  return items;
}

abstract class PersistedStore<T> {
  /** Erfüllt, sobald die initiale Ladung durch ist. Wirft nie. */
  readonly ready: Promise<void>;

  private readonly key: string;
  private readonly parse: Parse<T>;
  private readonly listeners = new Set<() => void>();
  private items: T[] = [];
  private version = 0;
  /** Schwanz der Schreib-Kette; startet an der Ladung. */
  private tail: Promise<unknown>;

  protected constructor(key: string, parse: Parse<T>) {
    this.key = key;
    this.parse = parse;
    this.ready = this.load();
    this.tail = this.ready;
  }

  subscribe = (cb: () => void): (() => void) => {
    this.listeners.add(cb);
    return () => {
      this.listeners.delete(cb);
    };
  };

  /** Zählt jede wirksame Mutation — Cache-Schlüssel für abgeleitete Snapshots. */
  getVersion(): number {
    return this.version;
  }

  protected get current(): T[] {
    return this.items;
  }

  /**
   * Führt `next` seriell hinter allen laufenden Schreibern aus. Gibt `next`
   * das Eingangs-Array unverändert zurück, passiert nichts: kein Write, keine
   * neue Version, keine Benachrichtigung (Snapshot bleibt referenzstabil).
   */
  protected async mutate(next: (items: T[]) => T[]): Promise<void> {
    const run = this.tail.then(async () => {
      const value = next(this.items);
      if (value === this.items) return;
      // Erst Platte, dann Speicher: schlägt der Write fehl, bleibt der
      // In-Memory-Stand der, der wirklich persistiert ist.
      await Preferences.set({ key: this.key, value: JSON.stringify(value) });
      this.items = value;
      this.version++;
      this.emit();
    });
    this.tail = run.catch(() => undefined);
    await run;
  }

  private async load(): Promise<void> {
    let raw: string | null = null;
    try {
      raw = (await Preferences.get({ key: this.key })).value;
    } catch {
      raw = null;
    }
    const items = parseList(raw, this.parse);
    if (items.length === 0) return;
    this.items = items;
    this.version++;
    this.emit();
  }

  private emit(): void {
    for (const cb of [...this.listeners]) cb();
  }
}

export class SpotStore extends PersistedStore<Spot> {
  constructor() {
    super(SPOTS_KEY, parseSpot);
  }

  getSpots(): Spot[] {
    return this.current;
  }

  async addSpot(d: { name: string; emoji: string; lng: number; lat: number }): Promise<Spot> {
    const spot: Spot = {
      id: crypto.randomUUID(),
      name: d.name,
      emoji: d.emoji,
      lng: d.lng,
      lat: d.lat,
      createdAt: Date.now(),
    };
    await this.mutate((items) => [...items, spot]);
    return spot;
  }

  /** Unbekannte id ist ein No-Op — Entfernen ist idempotent. */
  async removeSpot(id: string): Promise<void> {
    await this.mutate((items) =>
      items.some((s) => s.id === id) ? items.filter((s) => s.id !== id) : items,
    );
  }
}

/**
 * Freunde kommen erst mit dem CloudKit-Sync ins Gerät; lokal gibt es dafür
 * nur Laden + Lesen, keinen Schreibpfad (den hätte sonst niemand als Quelle).
 */
export class FriendStore extends PersistedStore<Friend> {
  constructor() {
    super(FRIENDS_KEY, parseFriend);
  }

  getFriends(): Friend[] {
    return this.current;
  }
}

function patchInvitation(
  items: Invitation[],
  id: string,
  patch: (inv: Invitation) => Invitation,
): Invitation[] {
  const index = items.findIndex((inv) => inv.id === id);
  // Lautlos schlucken hieße: die Antwort/Zeitänderung ist weg und niemand
  // erfährt es. Die id kommt aus dem eigenen Bestand — fehlt sie, ist es ein Bug.
  if (index === -1) throw new Error(`InviteStore: keine Einladung mit id "${id}"`);
  const next = items.slice();
  next[index] = patch(items[index]);
  return next;
}

export class InviteStore extends PersistedStore<Invitation> {
  constructor() {
    super(INVITES_KEY, parseInvitation);
  }

  getInvitations(): Invitation[] {
    return this.current;
  }

  /** Aktive Einladung des Spots; bei mehreren die zuletzt erstellte. */
  activeFor(spotId: string, now: number = Date.now()): Invitation | null {
    let best: Invitation | null = null;
    for (const inv of this.current) {
      if (inv.spotId !== spotId || !invitationActive(inv, now)) continue;
      if (best === null || inv.createdAt >= best.createdAt) best = inv;
    }
    return best;
  }

  /** `time` ist der Anker des Gastgebers („ab 20:00"), kein Vertrag. */
  async invite(spotId: string, time: number): Promise<Invitation> {
    const invitation: Invitation = {
      id: crypto.randomUUID(),
      spotId,
      hostId: SELF_ID,
      time,
      createdAt: Date.now(),
      cancelled: false,
      replies: [],
    };
    await this.mutate((items) => [...items, invitation]);
    return invitation;
  }

  /** Anker verschieben. Antworten BLEIBEN — sie tragen ihre eigene Zeit (v2.2). */
  async changeTime(id: string, time: number): Promise<void> {
    await this.mutate((items) => patchInvitation(items, id, (inv) => ({ ...inv, time })));
  }

  async cancel(id: string): Promise<void> {
    await this.mutate((items) => patchInvitation(items, id, (inv) => ({ ...inv, cancelled: true })));
  }

  /** Upsert pro participantId — jeder Teilnehmer hat genau eine Antwort. */
  async setReply(id: string, reply: Reply): Promise<void> {
    await this.mutate((items) =>
      patchInvitation(items, id, (inv) => {
        const index = inv.replies.findIndex((r) => r.participantId === reply.participantId);
        const replies = inv.replies.slice();
        if (index === -1) replies.push(reply);
        else replies[index] = reply;
        return { ...inv, replies };
      }),
    );
  }
}

export const spotStore = new SpotStore();
export const friendStore = new FriendStore();
export const inviteStore = new InviteStore();
