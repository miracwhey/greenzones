/**
 * CloudKit-Sync für Spots · Freunde · Einladungen (docs/cloudkit-contract.md).
 *
 * Pull-Snapshot-Modell: `fetchAll()` liefert immer den kompletten geteilten
 * Zustand, der hier in die lokalen Stores gemerged wird. Drei Regeln tragen
 * alles Weitere:
 *
 *  1. Wahrheit: Für geteilte Zonen gewinnt der Snapshot. Rein lokale Spots
 *     (ohne `zoneName`) und ihre Einladungen bleiben unberührt — sie sind
 *     Schublade A und haben in der Cloud kein Gegenstück.
 *  2. Idempotenz: Derselbe Snapshot zweimal ergibt exakt dieselben Listen. Der
 *     Merge sortiert deshalb alles, was aus der Cloud in beliebiger Reihenfolge
 *     kommen kann, und die Stores schreiben bei Inhaltsgleichheit nicht.
 *  3. Ehrlichkeit beim Schreiben: Einladung/Antwort gehen ZUERST in die Cloud
 *     und erst nach deren Bestätigung in den lokalen Store. Ohne Netz gibt es
 *     einen Abbruch mit Meldung — nie einen lokalen Zustand, der so tut, als
 *     wäre etwas gesendet. Einzige Ausnahme ist die Spot-Share-Anlage: sie ist
 *     laut Konzept nachholbar und liegt als `sharePending` in der Outbox.
 */
import { App } from "@capacitor/app";
import { Preferences } from "@capacitor/preferences";
import {
  CloudKitSync,
  cloudMessage,
  type CKAccountStatus,
  type CloudInvitation,
  type CloudKitSyncPlugin,
  type CloudSnapshot,
  type CloudSpot,
} from "../cloudkit";
import { FriendStore, InviteStore, SpotStore, deepEqual, friendStore, inviteStore, spotStore } from "./store";
import type { Friend, Invitation, Reply, Spot } from "./types";
import { SELF_ID } from "./types";

export const DISPLAY_NAME_KEY = "gz_display_name";
export const PROFILE_EMOJI_KEY = "gz_profile_emoji";
/** „Profil einrichten" nach einem Beitritt wurde gezeigt und beantwortet oder übersprungen. */
export const PROFILE_ASKED_KEY = "gz_profile_asked";

/** Avatar-Farben aus dem Mockup — deterministisch aus der userID, damit ein Merge nichts umfärbt. */
const FRIEND_COLORS = ["#7C5CFF", "#0A9B8E", "#0A84FF", "#F76B15", "#12A150", "#E5484D"];

export function friendColor(userID: string): string {
  let hash = 0;
  for (let i = 0; i < userID.length; i++) hash = (hash * 31 + userID.charCodeAt(i)) >>> 0;
  return FRIEND_COLORS[hash % FRIEND_COLORS.length];
}

/** Zonen-Name `spot-<uuid>` → lokale Spot-id; beide Seiten leiten sie gleich ab. */
export function localSpotId(zoneName: string): string {
  return zoneName.startsWith("spot-") ? zoneName.slice(5) : zoneName;
}

function cmp(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

export interface LocalState {
  spots: Spot[];
  friends: Friend[];
  invitations: Invitation[];
}

function fromCloudSpot(cloud: CloudSpot, self: (id: string) => string, local: Spot | null): Spot {
  const spot: Spot = {
    id: local?.id ?? localSpotId(cloud.zoneName),
    name: cloud.name,
    emoji: cloud.emoji,
    lng: cloud.lng,
    lat: cloud.lat,
    createdAt: cloud.createdAt,
    zoneName: cloud.zoneName,
    ownerId: cloud.isMine ? SELF_ID : self(cloud.ownerUserID),
    participantIds: cloud.participantUserIDs.map(self).filter((id) => id !== SELF_ID).sort(cmp),
  };
  if (cloud.shareURL) spot.shareURL = cloud.shareURL;
  return spot;
}

/** Antworten sind Upserts pro Person und werden nie gelöscht: Cloud gewinnt, lokale Extras bleiben. */
function mergeReplies(local: Reply[], cloud: Reply[]): Reply[] {
  const byParticipant = new Map(local.map((r) => [r.participantId, r]));
  for (const reply of cloud) byParticipant.set(reply.participantId, reply);
  return [...byParticipant.values()].sort((a, b) => cmp(a.participantId, b.participantId));
}

function fromCloudInvitation(
  cloud: CloudInvitation,
  spotId: string,
  self: (id: string) => string,
  local: Invitation | null,
): Invitation {
  return {
    id: cloud.id,
    spotId,
    hostId: self(cloud.hostUserID),
    time: cloud.time,
    createdAt: cloud.createdAt,
    cancelled: cloud.cancelled,
    replies: mergeReplies(
      local?.replies ?? [],
      cloud.replies.map((r) => ({
        participantId: self(r.participantUserID),
        status: r.status,
        ...(r.arrivalTime === undefined ? {} : { arrivalTime: r.arrivalTime }),
      })),
    ),
  };
}

/**
 * Merge des Cloud-Snapshots in den lokalen Bestand. Pur und ohne Seiteneffekt,
 * damit Idempotenz prüfbar ist.
 *
 * Zwei bewusste Grenzen der Regel „Cloud gewinnt":
 *  - Ein EIGENER geteilter Spot verschwindet nicht, nur weil er in einem
 *    Snapshot fehlt (CloudKit-Abfragen laufen der Anlage hinterher). Entfernt
 *    wird er ausschließlich durch die bewusste Handlung `SpotSync.removeSpot`.
 *  - Einladungen werden nie gelöscht, sondern abgesagt (`cancelled`). Eine im
 *    Snapshot fehlende Einladung heißt also „noch nicht sichtbar", nicht „weg".
 *    Sie verschwindet nur mit ihrem Spot.
 */
export function mergeSnapshot(snapshot: CloudSnapshot, current: LocalState): LocalState {
  const self = (id: string): string => (id !== "" && id === snapshot.userID ? SELF_ID : id);

  const friends: Friend[] = snapshot.friends
    .map((f) => ({
      id: f.userID,
      name: f.name,
      emoji: f.emoji,
      color: friendColor(f.userID),
      friendshipZone: f.friendshipZone,
    }))
    .sort((a, b) => cmp(a.name, b.name) || cmp(a.id, b.id));

  const open = new Map(snapshot.spots.map((s) => [s.zoneName, s]));
  const spots: Spot[] = [];
  for (const spot of current.spots) {
    if (!spot.zoneName) {
      spots.push(spot);
      continue;
    }
    const cloud = open.get(spot.zoneName);
    if (cloud) {
      spots.push(fromCloudSpot(cloud, self, spot));
      open.delete(spot.zoneName);
    } else if (spot.ownerId === SELF_ID) {
      spots.push(spot);
    }
  }
  for (const cloud of [...open.values()].sort(
    (a, b) => a.createdAt - b.createdAt || cmp(a.zoneName, b.zoneName),
  )) {
    spots.push(fromCloudSpot(cloud, self, null));
  }

  const spotIdByZone = new Map<string, string>();
  for (const spot of spots) if (spot.zoneName) spotIdByZone.set(spot.zoneName, spot.id);
  const knownSpotIds = new Set(spots.map((s) => s.id));

  const openInvites = new Map<string, CloudInvitation>();
  for (const inv of snapshot.invitations) {
    if (spotIdByZone.has(inv.spotZone)) openInvites.set(inv.id, inv);
  }
  const invitations: Invitation[] = [];
  for (const inv of current.invitations) {
    if (!knownSpotIds.has(inv.spotId)) continue;
    const cloud = openInvites.get(inv.id);
    if (!cloud) {
      invitations.push(inv);
      continue;
    }
    invitations.push(fromCloudInvitation(cloud, inv.spotId, self, inv));
    openInvites.delete(inv.id);
  }
  for (const cloud of [...openInvites.values()].sort(
    (a, b) => a.createdAt - b.createdAt || cmp(a.id, b.id),
  )) {
    const spotId = spotIdByZone.get(cloud.spotZone);
    if (spotId !== undefined) invitations.push(fromCloudInvitation(cloud, spotId, self, null));
  }

  return { spots, friends, invitations };
}

// ------------------------------------------------------------------- Engine

export interface SyncState {
  /** Kontostatus der letzten Prüfung; „unknown" = noch nie gefragt. */
  status: CKAccountStatus | "unknown";
  /** true, sobald ein Snapshot verarbeitet wurde. */
  loaded: boolean;
  /** Eigener Anzeigename (lokal persistiert); "" = noch nie gesetzt. */
  displayName: string;
  /** Eigenes Zeichen; "" = keins gewählt (eine gültige Wahl, kein fehlender Wert). */
  emoji: string;
  /**
   * Es gibt Freunde, aber noch kein eigenes Profil, und der Nutzer wurde nach
   * dem Beitritt noch nicht gefragt. Zustandsbasiert statt an das Accept-Event
   * gehängt: nach einem Kaltstart über den Share-Link ist das Event längst
   * verpufft, der Zustand aber noch da.
   */
  profilePrompt: boolean;
  /** Letzte Meldung an den Nutzer (blameless) oder null. */
  error: string | null;
  /** Spot-Shares, die noch in der Outbox liegen. */
  pendingShares: number;
}

const INITIAL: SyncState = {
  status: "unknown",
  loaded: false,
  displayName: "",
  emoji: "",
  profilePrompt: false,
  error: null,
  pendingShares: 0,
};

/** Abmeldung eines Listeners. */
type Unlisten = () => void;

export interface SyncDeps {
  plugin: CloudKitSyncPlugin;
  spots: SpotStore;
  friends: FriendStore;
  invites: InviteStore;
  /** App-Lebenszyklus; injizierbar, damit der Test keine Browser-Globals braucht. */
  appState: (onActive: (active: boolean) => void) => Promise<Unlisten>;
}

const defaultAppState = async (onActive: (active: boolean) => void): Promise<Unlisten> => {
  const handle = await App.addListener("appStateChange", ({ isActive }) => onActive(isActive));
  return () => {
    void handle.remove();
  };
};

export class SpotSync {
  private readonly deps: SyncDeps;
  private readonly listeners = new Set<() => void>();
  private state: SyncState = INITIAL;
  private started = false;
  private subscribed = false;
  private unlisten: Unlisten[] = [];
  /** Läuft gerade ein Fetch, wird ein zweiter Wunsch gesammelt statt parallel gefeuert. */
  private running: Promise<void> | null = null;
  private queued = false;
  /** Schwanz der Outbox-Kette. */
  private flushing: Promise<void> = Promise.resolve();
  /** Profil-Frage nach einem Beitritt wurde beantwortet oder übersprungen. */
  private profileAsked = false;

  constructor(deps: Partial<SyncDeps> = {}) {
    this.deps = {
      plugin: deps.plugin ?? CloudKitSync,
      spots: deps.spots ?? spotStore,
      friends: deps.friends ?? friendStore,
      invites: deps.invites ?? inviteStore,
      appState: deps.appState ?? defaultAppState,
    };
  }

  subscribe = (cb: () => void): (() => void) => {
    this.listeners.add(cb);
    return () => {
      this.listeners.delete(cb);
    };
  };

  /** Referenzstabil bis zur nächsten echten Änderung (useSyncExternalStore). */
  getState = (): SyncState => this.state;

  get available(): boolean {
    return this.state.status === "available";
  }

  /** Meldung quittieren — sie ist ein Hinweis, kein Dauerzustand. */
  clearError(): void {
    this.patch({ error: null });
  }

  /**
   * Start nach der lokalen Ladung: Kontostatus → Listener → erster Fetch.
   * Mehrfachaufruf ist ein No-Op (StrictMode-Doppelmount).
   */
  async start(): Promise<void> {
    if (this.started) return;
    this.started = true;
    await Promise.all([this.deps.spots.ready, this.deps.friends.ready, this.deps.invites.ready]);
    const [displayName, emoji, asked] = await Promise.all([
      loadPref(DISPLAY_NAME_KEY),
      loadPref(PROFILE_EMOJI_KEY),
      loadPref(PROFILE_ASKED_KEY),
    ]);
    this.profileAsked = asked === "1";
    this.patch({ displayName, emoji });
    // Am lokalen Bestand bewerten, nicht erst nach einem geglückten Fetch: die
    // Freunde von gestern liegen längst auf dem Gerät, und ohne Netz käme die
    // Frage sonst gar nicht.
    this.evaluateProfilePrompt();
    this.maybeAskNotificationPermission();
    try {
      const { status } = await this.deps.plugin.getAccountStatus();
      this.patch({ status });
    } catch {
      // Kein Grund für eine Meldung — fetchAll liefert den Status gleich noch einmal.
    }
    const cloud = await this.deps.plugin.addListener("cloudChanged", () => {
      void this.refresh();
    });
    this.unlisten.push(() => {
      void cloud.remove();
    });
    this.unlisten.push(
      await this.deps.appState((active) => {
        if (active) void this.refresh();
      }),
    );
    await this.refresh();
  }

  stop(): void {
    for (const off of this.unlisten) off();
    this.unlisten = [];
    this.started = false;
  }

  /** Kompletten Zustand holen und mergen. Parallele Aufrufe laufen seriell. */
  async refresh(): Promise<void> {
    if (this.running) {
      this.queued = true;
      await this.running;
      return;
    }
    this.running = this.fetchAndMerge().finally(() => {
      this.running = null;
    });
    await this.running;
    if (this.queued) {
      this.queued = false;
      await this.refresh();
    }
  }

  /**
   * Mitteilungs-Erlaubnis erst erfragen, wenn es etwas mitzuteilen gibt: mit dem
   * ersten Freund. Bewertet am LOKALEN Bestand (wie der Profil-Prompt) — die Freunde
   * von gestern liegen auf dem Gerät, ohne Netz käme die Frage sonst nie. Kein eigenes
   * Flag: der Systemstatus merkt sich die Antwort, Folgeaufrufe zeigen keinen Dialog.
   */
  private maybeAskNotificationPermission(): void {
    if (this.deps.friends.getFriends().length === 0) return;
    // Ohne Erlaubnis bleibt alles nutzbar — es gibt nur keine Banner.
    void this.deps.plugin.ensureNotificationPermission().catch(() => {});
  }

  private async fetchAndMerge(): Promise<void> {
    // Der Merge rechnet gegen den lokalen Bestand — vor der Ladung wäre das
    // eine leere Basis und würde alles Persistierte überschreiben.
    await Promise.all([this.deps.spots.ready, this.deps.friends.ready, this.deps.invites.ready]);
    let snapshot: CloudSnapshot;
    try {
      snapshot = await this.deps.plugin.fetchAll();
    } catch (error) {
      this.patch({ error: cloudMessage(error) });
      return;
    }
    this.patch({ status: snapshot.status, loaded: true, error: null });
    // Kein Konto ist ein definierter Zustand: nichts mergen, nichts löschen —
    // der lokale Bestand bleibt exakt, wie er ist.
    if (snapshot.status !== "available") return;

    const merged = mergeSnapshot(snapshot, {
      spots: this.deps.spots.getSpots(),
      friends: this.deps.friends.getFriends(),
      invitations: this.deps.invites.getInvitations(),
    });
    await this.deps.friends.replaceAll(merged.friends);
    await this.deps.spots.replaceAll(merged.spots);
    await this.deps.invites.replaceAll(merged.invitations);
    this.evaluateProfilePrompt();

    if (!this.subscribed) {
      try {
        await this.deps.plugin.registerSubscriptions();
        this.subscribed = true;
      } catch {
        // Push ist Komfort, kein Datenpfad — der nächste Fetch versucht es erneut.
      }
    }
    this.maybeAskNotificationPermission();
    await this.flushShares();
  }

  // ---------------------------------------------------------- Spots teilen

  /**
   * Spot anlegen. Ohne gewählte Freunde bleibt er rein lokal; mit Freunden geht
   * er in die Outbox und wird sofort (und sonst beim nächsten Fetch) zugestellt.
   */
  async createSpot(
    d: { name: string; emoji: string; lng: number; lat: number },
    friendIds: string[] = [],
  ): Promise<Spot> {
    const spot = await this.deps.spots.addSpot(d);
    if (friendIds.length > 0) await this.shareSpot(spot.id, friendIds);
    return spot;
  }

  /** Bestehenden eigenen Spot (weiteren) Freunden zustellen. */
  async shareSpot(spotId: string, friendIds: string[]): Promise<void> {
    const spot = this.deps.spots.getSpots().find((s) => s.id === spotId);
    if (!spot || friendIds.length === 0) return;
    const participants = [...new Set([...(spot.participantIds ?? []), ...friendIds])].sort(cmp);
    await this.deps.spots.setCloudState(spotId, {
      ownerId: SELF_ID,
      participantIds: participants,
      sharePending: true,
    });
    await this.flushShares();
  }

  /**
   * Outbox abarbeiten: Zone + Share anlegen, danach den Freunden zustellen.
   * Läuft seriell hinter allen laufenden Flushes — zwei parallele Läufe würden
   * denselben Spot beide als „ohne Zone" lesen und zweimal anlegen.
   */
  private flushShares(): Promise<void> {
    const run = this.flushing.then(() => this.flushPending());
    this.flushing = run.catch(() => undefined);
    return run;
  }

  private async flushPending(): Promise<void> {
    for (const spot of this.deps.spots.getSpots().filter((s) => s.sharePending)) {
      try {
        await this.pushShare(spot);
      } catch (error) {
        // Kein Netz/kein Konto: der Spot bleibt in der Outbox, lokal ist er längst da.
        this.patch({ error: cloudMessage(error) });
        break;
      }
    }
    this.patch({ pendingShares: this.deps.spots.getSpots().filter((s) => s.sharePending).length });
  }

  private async pushShare(spot: Spot): Promise<void> {
    let zoneName = spot.zoneName;
    let shareURL = spot.shareURL;
    if (!zoneName || !shareURL) {
      const created = await this.deps.plugin.createSpotShare({
        id: spot.id,
        name: spot.name,
        emoji: spot.emoji,
        lng: spot.lng,
        lat: spot.lat,
        createdAt: spot.createdAt,
      });
      zoneName = created.zoneName;
      shareURL = created.shareURL;
      await this.deps.spots.setCloudState(spot.id, { zoneName, shareURL, ownerId: SELF_ID });
    }
    const friendshipZones = this.zonesOf(spot.participantIds ?? []);
    if (friendshipZones.length > 0) {
      await this.deps.plugin.offerSpotToFriends({
        zoneName,
        shareURL,
        spotName: spot.name,
        spotEmoji: spot.emoji,
        friendshipZones,
      });
    }
    await this.deps.spots.setCloudState(spot.id, { sharePending: false });
  }

  private zonesOf(friendIds: string[]): string[] {
    const zones = new Map(this.deps.friends.getFriends().map((f) => [f.id, f.friendshipZone]));
    return friendIds.map((id) => zones.get(id)).filter((zone): zone is string => Boolean(zone));
  }

  /** Owner löscht die Zone, Teilnehmer beendet die Teilnahme — beides erst in der Cloud. */
  async removeSpot(spotId: string): Promise<void> {
    const spot = this.deps.spots.getSpots().find((s) => s.id === spotId);
    if (spot?.zoneName) await this.deps.plugin.deleteSpot({ zoneName: spot.zoneName });
    await this.deps.spots.removeSpot(spotId);
  }

  // ------------------------------------------------------- Einladungen

  /** Einladung anlegen — bei geteiltem Spot erst in der Cloud, dann lokal. */
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
    await this.mirrorInvitation(invitation);
    await this.deps.invites.add(invitation);
    return invitation;
  }

  async changeInvitationTime(invitationId: string, time: number): Promise<void> {
    const invitation = this.invitation(invitationId);
    await this.mirrorInvitation({ ...invitation, time });
    await this.deps.invites.changeTime(invitationId, time);
  }

  async cancelInvitation(invitationId: string): Promise<void> {
    const invitation = this.invitation(invitationId);
    await this.mirrorInvitation({ ...invitation, cancelled: true });
    await this.deps.invites.cancel(invitationId);
  }

  /** Eigene Antwort — „Ich komme um …" ist eine Zusage mit eigener Zeit. */
  async reply(invitationId: string, status: "in" | "out", arrivalTime?: number): Promise<void> {
    const invitation = this.invitation(invitationId);
    const zone = this.zoneOfSpot(invitation.spotId);
    if (zone) {
      await this.deps.plugin.saveReply({
        spotZone: zone,
        invitationId,
        status,
        ...(arrivalTime === undefined ? {} : { arrivalTime }),
      });
      void this.refresh();
    }
    await this.deps.invites.setReply(invitationId, {
      participantId: SELF_ID,
      status,
      ...(arrivalTime === undefined ? {} : { arrivalTime }),
    });
  }

  private invitation(invitationId: string): Invitation {
    const invitation = this.deps.invites.getInvitations().find((i) => i.id === invitationId);
    if (!invitation) throw new Error(`SpotSync: keine Einladung mit id "${invitationId}"`);
    return invitation;
  }

  private zoneOfSpot(spotId: string): string | undefined {
    return this.deps.spots.getSpots().find((s) => s.id === spotId)?.zoneName;
  }

  private async mirrorInvitation(invitation: Invitation): Promise<void> {
    const spotZone = this.zoneOfSpot(invitation.spotId);
    if (!spotZone) return;
    await this.deps.plugin.saveInvitation({
      spotZone,
      id: invitation.id,
      time: invitation.time,
      createdAt: invitation.createdAt,
      cancelled: invitation.cancelled,
    });
    void this.refresh();
  }

  // ----------------------------------------------------------- Freunde

  /**
   * Anzeigename lokal festhalten und, sofern es schon Freundschaften gibt,
   * deren Profile nachziehen. Der Name ist frei wählbar — kein Login, kein
   * Verzeichnis.
   */
  /**
   * Eigenes Profil festhalten und, sofern es schon Freundschaften gibt, deren
   * Profile-Records nachziehen. Name und Zeichen sind frei wählbar — kein Login,
   * kein Verzeichnis. Ein leeres Zeichen ist die Wahl „Ohne", kein Fehlwert:
   * es wird geschrieben und löscht ein früher gewähltes.
   */
  async setProfile(name: string, emoji: string): Promise<void> {
    const trimmed = name.trim();
    if (!trimmed) return;
    const unchanged = trimmed === this.state.displayName && emoji === this.state.emoji;
    // Auch unverändert muss die Frage als beantwortet gelten, sonst kommt sie wieder.
    await this.markProfileAsked();
    if (unchanged) return;
    await Preferences.set({ key: DISPLAY_NAME_KEY, value: trimmed });
    await Preferences.set({ key: PROFILE_EMOJI_KEY, value: emoji });
    this.patch({ displayName: trimmed, emoji });
    if (this.deps.friends.getFriends().length > 0) {
      await this.deps.plugin.setProfile({ name: trimmed, emoji });
    }
  }

  /** „Später"/„Überspringen": die Frage ruht, das Profil bleibt über die Freundesliste erreichbar. */
  async skipProfilePrompt(): Promise<void> {
    await this.markProfileAsked();
  }

  private async markProfileAsked(): Promise<void> {
    this.profileAsked = true;
    this.patch({ profilePrompt: false });
    try {
      await Preferences.set({ key: PROFILE_ASKED_KEY, value: "1" });
    } catch {
      // Nicht persistiert heißt: die Frage kommt beim nächsten Start noch einmal.
      // Lästig, aber harmlos — und besser als ein verschluckter Schreibfehler.
    }
  }

  private evaluateProfilePrompt(): void {
    const hasFriends = this.deps.friends.getFriends().length > 0;
    this.patch({
      profilePrompt: hasFriends && this.state.displayName === "" && !this.profileAsked,
    });
  }

  /** Einladungs-Link für einen neuen Freund; der Aufrufer schickt ihn übers Share-Sheet. */
  async inviteFriend(displayName: string, emoji: string = this.state.emoji): Promise<string> {
    await this.setProfile(displayName, emoji);
    const { url } = await this.deps.plugin.createFriendInvite({
      displayName: this.state.displayName,
      emoji: this.state.emoji,
    });
    void this.refresh();
    return url;
  }

  private patch(next: Partial<SyncState>): void {
    const merged = { ...this.state, ...next };
    if (deepEqual(merged, this.state)) return;
    this.state = merged;
    for (const cb of [...this.listeners]) cb();
  }
}

async function loadPref(key: string): Promise<string> {
  try {
    return (await Preferences.get({ key })).value ?? "";
  } catch {
    return "";
  }
}

export const spotSync = new SpotSync();
