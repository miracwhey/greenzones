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

function strings(value: unknown): boolean {
  return Array.isArray(value) && value.every((v) => typeof v === "string");
}

function optional(value: unknown, kind: "string" | "boolean" | "strings"): boolean {
  if (value === undefined) return true;
  return kind === "strings" ? strings(value) : typeof value === kind;
}

/**
 * Cloud-Felder sind eine Ergänzung, kein Existenzgrund: ist eines davon kaputt,
 * fällt der Spot auf seinen lokalen Kern zurück statt ganz zu verschwinden.
 * Alteinträge ohne diese Felder gehen unverändert durch.
 */
function parseSpot(value: unknown): Spot | null {
  const r = record(value);
  if (!r) return null;
  if (
    typeof r.id !== "string" ||
    typeof r.name !== "string" ||
    typeof r.emoji !== "string" ||
    typeof r.lng !== "number" ||
    typeof r.lat !== "number" ||
    typeof r.createdAt !== "number"
  ) {
    return null;
  }
  const spot = value as Spot;
  if (
    optional(spot.zoneName, "string") &&
    optional(spot.ownerId, "string") &&
    optional(spot.shareURL, "string") &&
    optional(spot.sharePending, "boolean") &&
    optional(spot.participantIds, "strings")
  ) {
    return spot;
  }
  const { id, name, emoji, lng, lat, createdAt } = spot;
  return { id, name, emoji, lng, lat, createdAt };
}

function parseFriend(value: unknown): Friend | null {
  const r = record(value);
  if (!r) return null;
  if (typeof r.id !== "string" || typeof r.name !== "string" || typeof r.color !== "string") {
    return null;
  }
  const friend = value as Friend;
  if (optional(friend.friendshipZone, "string")) return friend;
  const { id, name, color } = friend;
  return { id, name, color };
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

/**
 * Struktureller Vergleich für den Sync-Merge: ein Feld, das den JSON-Roundtrip
 * nicht überlebt (`undefined` vs. fehlend), darf keine Scheinänderung erzeugen —
 * sonst schriebe jeder Fetch dieselben Daten neu und die UI rendert grundlos.
 */
export function deepEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
    return a.every((item, i) => deepEqual(item, b[i]));
  }
  const ra = record(a);
  const rb = record(b);
  if (!ra || !rb) return false;
  for (const key of new Set([...Object.keys(ra), ...Object.keys(rb)])) {
    if (!deepEqual(ra[key], rb[key])) return false;
  }
  return true;
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
  /**
   * Ersetzt den Bestand durch das Ergebnis eines Sync-Merges. Inhaltsgleich =
   * keine Mutation (derselbe Snapshot zweimal darf die UI nicht anfassen).
   */
  async replaceAll(next: T[]): Promise<void> {
    await this.mutate((items) => (deepEqual(items, next) ? items : next));
  }

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

  /**
   * Cloud-Zustand eines Spots (Zone, Teilnehmer, Outbox-Flag). Unbekannte id ist
   * ein No-Op: der Spot kann während des Cloud-Writes entfernt worden sein.
   */
  async setCloudState(id: string, patch: SpotCloudState): Promise<void> {
    await this.mutate((items) => {
      const index = items.findIndex((s) => s.id === id);
      if (index === -1) return items;
      const next = { ...items[index], ...patch };
      if (deepEqual(next, items[index])) return items;
      const list = items.slice();
      list[index] = next;
      return list;
    });
  }
}

/** Cloud-Anteil eines Spots — der lokale Kern (Name, Position) gehört dem Nutzer. */
export type SpotCloudState = Partial<
  Pick<Spot, "zoneName" | "ownerId" | "participantIds" | "shareURL" | "sharePending">
>;

/**
 * Freunde entstehen ausschließlich aus dem CloudKit-Sync (Freundesliste = Menge
 * der Friendship-Zonen). Geschrieben wird deshalb nur über `replaceAll` aus dem
 * Merge — es gibt keinen lokalen „Freund anlegen"-Pfad, der eine zweite Quelle
 * wäre.
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
    await this.add(invitation);
    return invitation;
  }

  /**
   * Übernimmt eine fertige Einladung. Der Sync schreibt bei geteilten Spots
   * zuerst in die Cloud und braucht dieselbe id auf beiden Seiten.
   */
  async add(invitation: Invitation): Promise<void> {
    await this.mutate((items) => [...items, invitation]);
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
