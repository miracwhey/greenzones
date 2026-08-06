/**
 * Der Fake steht EXAKT auf den Contract-Typen (docs/cloudkit-contract.md) —
 * `implements CloudKitSyncPlugin` und Snapshot-Bauteile ohne ein einziges
 * erfundenes Feld. Ein Mock mit eigener Form würde hier grün werden und auf
 * dem Gerät scheitern.
 *
 * Storage wie in store.test.ts: echtes @capacitor/preferences über einen
 * gestubbten localStorage — die Persistenz-Schicht bleibt im Test.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type {
  CKAccountStatus,
  CloudFriend,
  CloudInvitation,
  CloudKitSyncPlugin,
  CloudSnapshot,
  CloudSpot,
} from "../../cloudkit";
import { cloudError } from "../../cloudkit";
import { FriendStore, InviteStore, SpotStore } from "../store";
import { SpotSync, mergeSnapshot, type LocalState } from "../sync";
import type { Invitation, Spot } from "../types";
import { SELF_ID } from "../types";

const ME = "_me001";
const TARA = "_tara01";
const MARCEL = "_marcel1";

let storage: Map<string, string>;

beforeEach(() => {
  storage = new Map<string, string>();
  const impl = {
    getItem: (key: string): string | null => storage.get(key) ?? null,
    setItem: (key: string, value: string): void => {
      storage.set(key, value);
    },
    removeItem: (key: string): void => {
      storage.delete(key);
    },
  };
  vi.stubGlobal("window", { localStorage: impl });
  vi.stubGlobal("localStorage", impl);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

// ------------------------------------------------------------- Contract-Fake

function cloudSpot(p: Partial<CloudSpot> & { zoneName: string }): CloudSpot {
  return {
    ownerUserID: "",
    isMine: true,
    name: "Unsere Bank",
    emoji: "🪑",
    lng: 9.7218,
    lat: 52.3663,
    createdAt: 1000,
    participantUserIDs: [],
    shareURL: "",
    ...p,
  };
}

function cloudInvitation(p: Partial<CloudInvitation> & { id: string; spotZone: string }): CloudInvitation {
  return {
    hostUserID: ME,
    time: 1_800_000_000_000,
    createdAt: 900,
    cancelled: false,
    replies: [],
    ...p,
  };
}

function cloudFriend(p: Partial<CloudFriend> & { userID: string }): CloudFriend {
  return { name: "Tara", emoji: "", friendshipZone: `friend-${p.userID}`, isOwner: true, ...p };
}

function snapshot(p: Partial<CloudSnapshot> = {}): CloudSnapshot {
  return {
    status: "available",
    userID: ME,
    friends: [],
    spots: [],
    invitations: [],
    ...p,
  };
}

class FakePlugin implements CloudKitSyncPlugin {
  next: CloudSnapshot = snapshot();
  accountStatus: CKAccountStatus = "available";
  /** Methodenname → Fehler, den der nächste Aufruf wirft. */
  readonly fails = new Map<string, Error>();
  readonly calls: string[] = [];
  readonly shares: { zoneName: string; friendshipZones: string[] }[] = [];
  private cloudChanged: (() => void) | null = null;

  private guard(name: string): void {
    this.calls.push(name);
    const error = this.fails.get(name);
    if (error) throw error;
  }

  emitCloudChanged(): void {
    this.cloudChanged?.();
  }

  async getAccountStatus(): Promise<{ status: CKAccountStatus }> {
    this.guard("getAccountStatus");
    return { status: this.accountStatus };
  }

  async fetchAll(): Promise<CloudSnapshot> {
    this.guard("fetchAll");
    return this.next;
  }

  async createFriendInvite(opts: { displayName: string }): Promise<{ url: string }> {
    this.guard("createFriendInvite");
    return { url: `https://www.icloud.com/share/${opts.displayName}` };
  }

  async acceptShare(): Promise<void> {
    this.guard("acceptShare");
  }

  async setProfile(): Promise<void> {
    this.guard("setProfile");
  }

  async createSpotShare(opts: { id: string }): Promise<{ zoneName: string; shareURL: string }> {
    this.guard("createSpotShare");
    return { zoneName: `spot-${opts.id}`, shareURL: `https://www.icloud.com/share/${opts.id}` };
  }

  async offerSpotToFriends(opts: { zoneName: string; friendshipZones: string[] }): Promise<void> {
    this.guard("offerSpotToFriends");
    this.shares.push({ zoneName: opts.zoneName, friendshipZones: opts.friendshipZones });
  }

  async deleteSpot(): Promise<void> {
    this.guard("deleteSpot");
  }

  async saveInvitation(): Promise<void> {
    this.guard("saveInvitation");
  }

  async saveReply(): Promise<void> {
    this.guard("saveReply");
  }

  async registerSubscriptions(): Promise<void> {
    this.guard("registerSubscriptions");
  }

  async addListener(
    _eventName: "cloudChanged",
    listener: () => void,
  ): Promise<{ remove: () => Promise<void> }> {
    this.cloudChanged = listener;
    return {
      remove: async () => {
        this.cloudChanged = null;
      },
    };
  }
}

interface Harness {
  plugin: FakePlugin;
  spots: SpotStore;
  friends: FriendStore;
  invites: InviteStore;
  sync: SpotSync;
  setActive: (active: boolean) => void;
  /** Zonen je Zustellung — beweist, WEM der Spot angeboten wurde. */
  shareZones: () => string[][];
}

async function harness(): Promise<Harness> {
  const plugin = new FakePlugin();
  const spots = new SpotStore();
  const friends = new FriendStore();
  const invites = new InviteStore();
  let onActive: ((active: boolean) => void) | null = null;
  const sync = new SpotSync({
    plugin,
    spots,
    friends,
    invites,
    appState: async (cb) => {
      onActive = cb;
      return () => {
        onActive = null;
      };
    },
  });
  await Promise.all([spots.ready, friends.ready, invites.ready]);
  return {
    plugin,
    spots,
    friends,
    invites,
    sync,
    setActive: (active) => onActive?.(active),
    shareZones: () => plugin.shares.map((s) => s.friendshipZones),
  };
}

function local(partial: Partial<LocalState> = {}): LocalState {
  return { spots: [], friends: [], invitations: [], ...partial };
}

const LOCAL_SPOT: Spot = {
  id: "lokal-1",
  name: "Balkon",
  emoji: "🌳",
  lng: 9.7,
  lat: 52.3,
  createdAt: 500,
};

// ----------------------------------------------------------------- Merge

describe("mergeSnapshot", () => {
  it("mappt die eigene userID auf SELF_ID", () => {
    const merged = mergeSnapshot(
      snapshot({
        spots: [cloudSpot({ zoneName: "spot-a", isMine: false, ownerUserID: TARA, participantUserIDs: [ME, MARCEL] })],
        invitations: [
          cloudInvitation({
            id: "i1",
            spotZone: "spot-a",
            hostUserID: ME,
            replies: [
              { participantUserID: ME, status: "in", arrivalTime: 42 },
              { participantUserID: TARA, status: "out" },
            ],
          }),
        ],
      }),
      local(),
    );

    expect(merged.spots[0].ownerId).toBe(TARA);
    // „ohne mich": die eigene id taucht in der Teilnehmerliste nicht auf.
    expect(merged.spots[0].participantIds).toEqual([MARCEL]);
    expect(merged.invitations[0].hostId).toBe(SELF_ID);
    // Antworten liegen nach participantId sortiert — die Cloud-Reihenfolge ist
    // nicht stabil und würde sonst bei jedem Fetch eine Scheinänderung erzeugen.
    expect(merged.invitations[0].replies).toEqual([
      { participantId: TARA, status: "out" },
      { participantId: SELF_ID, status: "in", arrivalTime: 42 },
    ]);
  });

  it("ersetzt die lokale Kopie eines Fremd-Spots durch den Snapshot", () => {
    const stale: Spot = {
      id: "a",
      name: "Alter Name",
      emoji: "🪑",
      lng: 0,
      lat: 0,
      createdAt: 1000,
      zoneName: "spot-a",
      ownerId: TARA,
      participantIds: [],
    };
    const merged = mergeSnapshot(
      snapshot({
        spots: [
          cloudSpot({
            zoneName: "spot-a",
            isMine: false,
            ownerUserID: TARA,
            name: "Maschsee-Ecke",
            participantUserIDs: [MARCEL],
          }),
        ],
      }),
      local({ spots: [stale] }),
    );

    expect(merged.spots).toHaveLength(1);
    expect(merged.spots[0].name).toBe("Maschsee-Ecke");
    expect(merged.spots[0].participantIds).toEqual([MARCEL]);
  });

  it("lässt rein lokale Spots und ihre Einladungen unberührt", () => {
    const localInvite: Invitation = {
      id: "i-lokal",
      spotId: LOCAL_SPOT.id,
      hostId: SELF_ID,
      time: 1,
      createdAt: 1,
      cancelled: false,
      replies: [],
    };
    const merged = mergeSnapshot(
      snapshot({ spots: [cloudSpot({ zoneName: "spot-a" })] }),
      local({ spots: [LOCAL_SPOT], invitations: [localInvite] }),
    );

    expect(merged.spots[0]).toBe(LOCAL_SPOT);
    expect(merged.invitations).toEqual([localInvite]);
  });

  it("entfernt einen Fremd-Spot, der nicht mehr im Snapshot steht — den eigenen nicht", () => {
    const fremd: Spot = { ...LOCAL_SPOT, id: "a", zoneName: "spot-a", ownerId: TARA };
    const meins: Spot = { ...LOCAL_SPOT, id: "b", zoneName: "spot-b", ownerId: SELF_ID };
    const invite: Invitation = {
      id: "i1",
      spotId: "a",
      hostId: TARA,
      time: 1,
      createdAt: 1,
      cancelled: false,
      replies: [],
    };

    const merged = mergeSnapshot(snapshot(), local({ spots: [fremd, meins], invitations: [invite] }));
    expect(merged.spots.map((s) => s.id)).toEqual(["b"]);
    // Mit dem Spot geht auch seine Einladung — sonst bliebe eine Karteileiche.
    expect(merged.invitations).toEqual([]);
  });

  it("ist idempotent — auch wenn die Cloud die Reihenfolge dreht", () => {
    const first = snapshot({
      friends: [cloudFriend({ userID: TARA }), cloudFriend({ userID: MARCEL, name: "Marcel" })],
      spots: [
        cloudSpot({ zoneName: "spot-a", participantUserIDs: [TARA, MARCEL] }),
        cloudSpot({ zoneName: "spot-b", createdAt: 2000 }),
      ],
      invitations: [
        cloudInvitation({
          id: "i1",
          spotZone: "spot-a",
          replies: [
            { participantUserID: TARA, status: "in" },
            { participantUserID: MARCEL, status: "out" },
          ],
        }),
      ],
    });
    const shuffled = snapshot({
      friends: [...first.friends].reverse(),
      spots: [...first.spots].reverse(),
      invitations: first.invitations.map((i) => ({ ...i, replies: [...i.replies].reverse() })),
    });

    const once = mergeSnapshot(first, local({ spots: [LOCAL_SPOT] }));
    const twice = mergeSnapshot(shuffled, once);
    expect(twice).toEqual(once);
  });
});

// ---------------------------------------------------------------- Engine

describe("SpotSync", () => {
  it("fragt nach dem eigenen Profil, sobald es Freunde gibt und noch kein Name da ist", async () => {
    const h = await harness();
    // Ohne Freunde gibt es nichts zu erklären — die Frage wäre grundlos.
    expect(h.sync.getState().profilePrompt).toBe(false);

    h.plugin.next = snapshot({ friends: [cloudFriend({ userID: TARA })] });
    await h.sync.refresh();
    expect(h.sync.getState().profilePrompt).toBe(true);

    await h.sync.setProfile("Leon", "🌿");
    expect(h.sync.getState()).toMatchObject({
      displayName: "Leon",
      emoji: "🌿",
      profilePrompt: false,
    });
    // Mit bestehenden Freundschaften muss das Profil in deren Zonen nachgezogen werden.
    expect(h.plugin.calls).toContain("setProfile");
  });

  it("hält die Profil-Frage nach dem Überspringen auch über weitere Syncs ruhig", async () => {
    const h = await harness();
    h.plugin.next = snapshot({ friends: [cloudFriend({ userID: TARA })] });
    await h.sync.refresh();
    expect(h.sync.getState().profilePrompt).toBe(true);

    await h.sync.skipProfilePrompt();
    expect(h.sync.getState().profilePrompt).toBe(false);

    // Jeder weitere Sync bewertet den Prompt neu — „übersprungen" muss das überleben,
    // sonst kommt die Frage bei jedem Push zurück.
    await h.sync.refresh();
    expect(h.sync.getState().profilePrompt).toBe(false);
  });

  it("nimmt ein leeres Zeichen als Wahl an, nicht als fehlenden Wert", async () => {
    const h = await harness();
    h.plugin.next = snapshot({ friends: [cloudFriend({ userID: TARA })] });
    await h.sync.refresh();
    await h.sync.setProfile("Leon", "🌿");
    await h.sync.setProfile("Leon", "");
    expect(h.sync.getState().emoji).toBe("");
  });

  it("schreibt die Freunde aus dem Snapshot in den FriendStore", async () => {
    const h = await harness();
    h.plugin.next = snapshot({ friends: [cloudFriend({ userID: TARA })] });
    await h.sync.refresh();

    expect(h.friends.getFriends()).toEqual([
      {
        id: TARA,
        name: "Tara",
        emoji: "",
        color: expect.any(String),
        friendshipZone: `friend-${TARA}`,
      },
    ]);
    const reader = new FriendStore();
    await reader.ready;
    expect(reader.getFriends()[0].id).toBe(TARA);
  });

  it("noAccount: kein Merge, keine Store-Mutation, Status im State", async () => {
    const h = await harness();
    await h.spots.addSpot({ name: "Balkon", emoji: "🌳", lng: 9.7, lat: 52.3 });
    const before = h.spots.getSpots();
    const version = h.spots.getVersion();
    h.plugin.accountStatus = "noAccount";
    h.plugin.next = { status: "noAccount", userID: "", friends: [], spots: [], invitations: [] };

    await h.sync.refresh();

    expect(h.sync.getState().status).toBe("noAccount");
    expect(h.sync.available).toBe(false);
    expect(h.spots.getSpots()).toBe(before);
    expect(h.spots.getVersion()).toBe(version);
    expect(h.friends.getVersion()).toBe(0);
    expect(h.plugin.calls).not.toContain("registerSubscriptions");
  });

  it("derselbe Snapshot zweimal mutiert nichts", async () => {
    const h = await harness();
    h.plugin.next = snapshot({
      friends: [cloudFriend({ userID: TARA })],
      spots: [cloudSpot({ zoneName: "spot-a", participantUserIDs: [TARA] })],
      invitations: [cloudInvitation({ id: "i1", spotZone: "spot-a" })],
    });

    await h.sync.refresh();
    const spots = h.spots.getSpots();
    const friends = h.friends.getFriends();
    const invites = h.invites.getInvitations();
    const versions = [h.spots.getVersion(), h.friends.getVersion(), h.invites.getVersion()];

    await h.sync.refresh();

    expect(h.spots.getSpots()).toBe(spots);
    expect(h.friends.getFriends()).toBe(friends);
    expect(h.invites.getInvitations()).toBe(invites);
    expect([h.spots.getVersion(), h.friends.getVersion(), h.invites.getVersion()]).toEqual(versions);
  });

  it("registriert Subscriptions genau einmal", async () => {
    const h = await harness();
    await h.sync.refresh();
    await h.sync.refresh();
    expect(h.plugin.calls.filter((c) => c === "registerSubscriptions")).toHaveLength(1);
  });

  it("cloudChanged und appStateChange lösen einen Refetch aus", async () => {
    const h = await harness();
    await h.sync.start();
    const fetches = () => h.plugin.calls.filter((c) => c === "fetchAll").length;
    expect(fetches()).toBe(1);

    h.plugin.emitCloudChanged();
    await vi.waitFor(() => expect(fetches()).toBe(2));

    h.setActive(false);
    h.setActive(true);
    await vi.waitFor(() => expect(fetches()).toBe(3));
    h.sync.stop();
  });

  it("Einladung ohne Netz: Abbruch mit Meldung, kein lokaler „gesendet\"-Zustand", async () => {
    const h = await harness();
    h.plugin.next = snapshot({ spots: [cloudSpot({ zoneName: "spot-a" })] });
    await h.sync.refresh();
    const spot = h.spots.getSpots()[0];
    const version = h.invites.getVersion();

    h.plugin.fails.set("saveInvitation", cloudError("network", "offline"));
    await expect(h.sync.invite(spot.id, 1_800_000_000_000)).rejects.toMatchObject({
      code: "network",
    });

    expect(h.invites.getInvitations()).toEqual([]);
    expect(h.invites.getVersion()).toBe(version);
    const reader = new InviteStore();
    await reader.ready;
    expect(reader.getInvitations()).toEqual([]);
  });

  it("Antwort ohne Netz: keine lokale Antwort", async () => {
    const h = await harness();
    h.plugin.next = snapshot({
      spots: [cloudSpot({ zoneName: "spot-a", isMine: false, ownerUserID: TARA })],
      invitations: [cloudInvitation({ id: "i1", spotZone: "spot-a", hostUserID: TARA })],
    });
    await h.sync.refresh();

    h.plugin.fails.set("saveReply", cloudError("network", "offline"));
    await expect(h.sync.reply("i1", "in")).rejects.toMatchObject({ code: "network" });
    expect(h.invites.getInvitations()[0].replies).toEqual([]);
  });

  it("rein lokaler Spot: Einladung ohne einen einzigen Cloud-Write", async () => {
    const h = await harness();
    const spot = await h.spots.addSpot({ name: "Balkon", emoji: "🌳", lng: 9.7, lat: 52.3 });
    const inv = await h.sync.invite(spot.id, 1_800_000_000_000);

    expect(h.invites.getInvitations()).toEqual([inv]);
    expect(h.plugin.calls).toEqual([]);
  });

  it("Spot mit Freunden: Zone + Zustellung, danach ist die Outbox leer", async () => {
    const h = await harness();
    h.plugin.next = snapshot({ friends: [cloudFriend({ userID: TARA })] });
    await h.sync.refresh();

    const spot = await h.sync.createSpot(
      { name: "Unsere Bank", emoji: "🪑", lng: 9.72, lat: 52.36 },
      [TARA],
    );

    const stored = h.spots.getSpots()[0];
    expect(stored.zoneName).toBe(`spot-${spot.id}`);
    expect(stored.sharePending).toBe(false);
    expect(stored.ownerId).toBe(SELF_ID);
    expect(h.shareZones()).toEqual([[`friend-${TARA}`]]);
    expect(h.sync.getState().pendingShares).toBe(0);
  });

  it("Spot-Share ohne Netz bleibt in der Outbox und wird später nachgeholt", async () => {
    const h = await harness();
    h.plugin.next = snapshot({ friends: [cloudFriend({ userID: TARA })] });
    await h.sync.refresh();
    h.plugin.fails.set("createSpotShare", cloudError("network", "offline"));

    const spot = await h.sync.createSpot(
      { name: "Unsere Bank", emoji: "🪑", lng: 9.72, lat: 52.36 },
      [TARA],
    );

    // Lokal ist der Spot da, die Cloud-Anlage steht ehrlich als „offen" drin.
    expect(h.spots.getSpots()[0].sharePending).toBe(true);
    expect(h.spots.getSpots()[0].zoneName).toBeUndefined();
    expect(h.sync.getState().pendingShares).toBe(1);
    expect(h.sync.getState().error).not.toBeNull();

    h.plugin.fails.delete("createSpotShare");
    await h.sync.refresh();

    expect(h.spots.getSpots()[0].zoneName).toBe(`spot-${spot.id}`);
    expect(h.spots.getSpots()[0].sharePending).toBe(false);
    expect(h.shareZones()).toEqual([[`friend-${TARA}`]]);
  });

  it("zwei parallele Teil-Vorgänge legen die Zone nur einmal an", async () => {
    const h = await harness();
    h.plugin.next = snapshot({ friends: [cloudFriend({ userID: TARA }), cloudFriend({ userID: MARCEL, name: "Marcel" })] });
    await h.sync.refresh();
    const spot = await h.spots.addSpot({ name: "Unsere Bank", emoji: "🪑", lng: 9.72, lat: 52.36 });

    await Promise.all([h.sync.shareSpot(spot.id, [TARA]), h.sync.shareSpot(spot.id, [MARCEL])]);

    expect(h.plugin.calls.filter((c) => c === "createSpotShare")).toHaveLength(1);
    expect(h.spots.getSpots()[0].sharePending).toBe(false);
  });

  it("Spot entfernen: erst die Zone, dann lokal", async () => {
    const h = await harness();
    h.plugin.next = snapshot({ spots: [cloudSpot({ zoneName: "spot-a" })] });
    await h.sync.refresh();
    const spot = h.spots.getSpots()[0];

    h.plugin.fails.set("deleteSpot", cloudError("network", "offline"));
    await expect(h.sync.removeSpot(spot.id)).rejects.toMatchObject({ code: "network" });
    expect(h.spots.getSpots()).toHaveLength(1);

    h.plugin.fails.delete("deleteSpot");
    await h.sync.removeSpot(spot.id);
    expect(h.spots.getSpots()).toEqual([]);
  });

  it("Freund einladen: Name lokal, Link vom Plugin", async () => {
    const h = await harness();
    const url = await h.sync.inviteFriend("Leon");
    expect(url).toContain("Leon");
    expect(h.sync.getState().displayName).toBe("Leon");
    // Ohne bestehende Freundschaften gibt es kein Profil zu aktualisieren.
    expect(h.plugin.calls).not.toContain("setDisplayName");
  });
});
