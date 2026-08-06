/**
 * Getestet wird gegen die ECHTE @capacitor/preferences-Implementierung: im Web-
 * Fallback schreibt sie nach window.localStorage unter "CapacitorStorage.<key>".
 * Gestubbt wird nur der Browser-Global — nicht das Plugin. Ein vi.mock würde
 * genau die Schicht wegnehmen, deren Roundtrip hier bewiesen werden soll.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  FRIENDS_KEY,
  FriendStore,
  INVITES_KEY,
  InviteStore,
  SPOTS_KEY,
  SpotStore,
} from "../store";
import type { Friend, Invitation, Reply, Spot } from "../types";
import { INVITATION_LINGER_MS, invitationActive } from "../types";

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

/** Schreibt roh in den Storage — so, wie ein früherer App-Lauf ihn hinterlässt. */
function seed(key: string, raw: string): void {
  storage.set(`CapacitorStorage.${key}`, raw);
}

function stored(key: string): string | undefined {
  return storage.get(`CapacitorStorage.${key}`);
}

const BANK = { name: "Unsere Bank", emoji: "🌳", lng: 9.7218, lat: 52.3663 };
const HBF = { name: "Hbf", emoji: "🚉", lng: 9.7411, lat: 52.3767 };

function invitation(partial: Partial<Invitation> & { id: string; spotId: string }): Invitation {
  return {
    hostId: "me",
    time: 0,
    createdAt: 0,
    cancelled: false,
    replies: [],
    ...partial,
  };
}

describe("SpotStore", () => {
  it("startet leer, wenn nichts gespeichert ist", async () => {
    const store = new SpotStore();
    await store.ready;
    expect(store.getSpots()).toEqual([]);
  });

  it("persistiert unter gz_spots und liest über eine neue Instanz zurück", async () => {
    const writer = new SpotStore();
    await writer.ready;
    const spot = await writer.addSpot(BANK);

    expect(spot.id).not.toBe("");
    expect(spot.createdAt).toBeGreaterThan(0);
    expect(stored(SPOTS_KEY)).toBeDefined();

    const reader = new SpotStore();
    await reader.ready;
    expect(reader.getSpots()).toEqual([spot]);
  });

  it("removeSpot löscht auch aus dem Storage", async () => {
    const writer = new SpotStore();
    await writer.ready;
    const bank = await writer.addSpot(BANK);
    const hbf = await writer.addSpot(HBF);

    await writer.removeSpot(bank.id);
    expect(writer.getSpots()).toEqual([hbf]);

    const reader = new SpotStore();
    await reader.ready;
    expect(reader.getSpots()).toEqual([hbf]);
  });

  it("korrupter oder fremder Storage-Inhalt ergibt leeren Bestand statt Crash", async () => {
    seed(SPOTS_KEY, "{nope");
    const broken = new SpotStore();
    await expect(broken.ready).resolves.toBeUndefined();
    expect(broken.getSpots()).toEqual([]);

    seed(SPOTS_KEY, JSON.stringify({ spots: [] }));
    const notAList = new SpotStore();
    await notAList.ready;
    expect(notAList.getSpots()).toEqual([]);

    const good: Spot = { id: "s1", ...BANK, createdAt: 1 };
    seed(SPOTS_KEY, JSON.stringify([{ id: "kaputt" }, null, "text", good]));
    const partial = new SpotStore();
    await partial.ready;
    expect(partial.getSpots()).toEqual([good]);
  });

  it("Kaltstart ohne window/localStorage wirft nicht", async () => {
    vi.unstubAllGlobals();
    const store = new SpotStore();
    await expect(store.ready).resolves.toBeUndefined();
    expect(store.getSpots()).toEqual([]);
  });

  it("liefert bis zur nächsten Mutation dieselbe Snapshot-Referenz", async () => {
    const store = new SpotStore();
    await store.ready;
    const empty = store.getSpots();
    expect(store.getSpots()).toBe(empty);

    const spot = await store.addSpot(BANK);
    const filled = store.getSpots();
    expect(filled).not.toBe(empty);
    expect(store.getSpots()).toBe(filled);

    // No-Op darf keinen neuen Snapshot und keine neue Version erzeugen.
    const version = store.getVersion();
    await store.removeSpot("gibt-es-nicht");
    expect(store.getSpots()).toBe(filled);
    expect(store.getVersion()).toBe(version);

    await store.removeSpot(spot.id);
    expect(store.getSpots()).not.toBe(filled);
    expect(store.getVersion()).toBe(version + 1);
  });

  it("benachrichtigt Subscriber bei Mutationen und nicht mehr nach unsubscribe", async () => {
    const store = new SpotStore();
    await store.ready;
    let calls = 0;
    const unsubscribe = store.subscribe(() => {
      calls++;
    });

    const spot = await store.addSpot(BANK);
    expect(calls).toBe(1);

    unsubscribe();
    await store.removeSpot(spot.id);
    expect(calls).toBe(1);
  });

  it("parallele Writes gehen nicht verloren (serialisiert, kein Lost Update)", async () => {
    const store = new SpotStore();
    await store.ready;
    await Promise.all([store.addSpot(BANK), store.addSpot(HBF)]);

    expect(store.getSpots()).toHaveLength(2);
    const reader = new SpotStore();
    await reader.ready;
    expect(reader.getSpots().map((s) => s.name).sort()).toEqual(["Hbf", "Unsere Bank"]);
  });

  it("ein Write vor abgeschlossener Ladung überschreibt den Bestand nicht", async () => {
    const old: Spot = { id: "s1", ...BANK, createdAt: 1 };
    seed(SPOTS_KEY, JSON.stringify([old]));

    const store = new SpotStore();
    // bewusst OHNE await store.ready
    await store.addSpot(HBF);

    const spots = store.getSpots();
    expect(spots).toHaveLength(2);
    expect(spots[0]).toEqual(old);
    expect(spots[1].name).toBe(HBF.name);
  });
});

describe("Kaltstart mit Altbestand (vor dem CloudKit-Sync)", () => {
  // Wörtlich das Format, das die committete Version 2.2 persistiert hat —
  // kein zoneName, kein ownerId, kein friendshipZone.
  const OLD_SPOT = { id: "s1", name: "Unsere Bank", emoji: "🌳", lng: 9.7218, lat: 52.3663, createdAt: 1 };
  const OLD_FRIEND = { id: "f1", name: "Tara", color: "#7dd" };
  const OLD_INVITE = {
    id: "i1",
    spotId: "s1",
    hostId: "me",
    time: 5,
    createdAt: 4,
    cancelled: false,
    replies: [{ participantId: "f1", status: "in" }],
  };

  it("parst Spots, Freunde und Einladungen unverändert", async () => {
    seed(SPOTS_KEY, JSON.stringify([OLD_SPOT]));
    seed(FRIENDS_KEY, JSON.stringify([OLD_FRIEND]));
    seed(INVITES_KEY, JSON.stringify([OLD_INVITE]));

    const spots = new SpotStore();
    const friends = new FriendStore();
    const invites = new InviteStore();
    await Promise.all([spots.ready, friends.ready, invites.ready]);

    expect(spots.getSpots()).toEqual([OLD_SPOT]);
    expect(spots.getSpots()[0].zoneName).toBeUndefined();
    expect(friends.getFriends()).toEqual([OLD_FRIEND]);
    expect(invites.getInvitations()).toEqual([OLD_INVITE]);
  });

  it("verwirft ein kaputtes Cloud-Feld, nicht den Spot", async () => {
    seed(
      SPOTS_KEY,
      JSON.stringify([{ ...OLD_SPOT, zoneName: 7, participantIds: ["f1"], sharePending: true }]),
    );
    const store = new SpotStore();
    await store.ready;
    expect(store.getSpots()).toEqual([OLD_SPOT]);
  });

  it("nimmt gültige Cloud-Felder mit", async () => {
    const shared: Spot = { ...OLD_SPOT, zoneName: "spot-s1", ownerId: "me", participantIds: ["f1"] };
    seed(SPOTS_KEY, JSON.stringify([shared]));
    const store = new SpotStore();
    await store.ready;
    expect(store.getSpots()).toEqual([shared]);
  });
});

describe("SpotStore Cloud-Zustand", () => {
  it("setCloudState schreibt nur bei echter Änderung", async () => {
    const store = new SpotStore();
    await store.ready;
    const spot = await store.addSpot(BANK);
    const version = store.getVersion();

    await store.setCloudState(spot.id, { zoneName: `spot-${spot.id}`, participantIds: ["f1"] });
    expect(store.getVersion()).toBe(version + 1);
    expect(store.getSpots()[0].zoneName).toBe(`spot-${spot.id}`);

    const after = store.getSpots();
    await store.setCloudState(spot.id, { zoneName: `spot-${spot.id}`, participantIds: ["f1"] });
    expect(store.getSpots()).toBe(after);
    expect(store.getVersion()).toBe(version + 1);

    // Unbekannte id ist ein No-Op (der Spot kann inzwischen entfernt sein).
    await store.setCloudState("gibt-es-nicht", { sharePending: true });
    expect(store.getSpots()).toBe(after);
  });

  it("replaceAll ist bei inhaltsgleicher Liste eine Nulloperation", async () => {
    const store = new SpotStore();
    await store.ready;
    await store.addSpot(BANK);
    const before = store.getSpots();
    const version = store.getVersion();

    await store.replaceAll(before.map((s) => ({ ...s })));
    expect(store.getSpots()).toBe(before);
    expect(store.getVersion()).toBe(version);

    await store.replaceAll([]);
    expect(store.getSpots()).toEqual([]);
    expect(store.getVersion()).toBe(version + 1);
  });
});

describe("FriendStore", () => {
  it("ist lokal leer, bis der Sync etwas hinterlegt hat", async () => {
    const store = new FriendStore();
    await store.ready;
    expect(store.getFriends()).toEqual([]);
  });

  it("bekommt seinen Bestand über replaceAll aus dem Sync", async () => {
    const store = new FriendStore();
    await store.ready;
    const tara: Friend = { id: "f1", name: "Tara", color: "#7dd", friendshipZone: "friend-1" };
    await store.replaceAll([tara]);

    const reader = new FriendStore();
    await reader.ready;
    expect(reader.getFriends()).toEqual([tara]);
  });

  it("liest hinterlegte Freunde unter gz_friends und filtert kaputte Einträge", async () => {
    const tara: Friend = { id: "f1", name: "Tara", color: "#7dd" };
    seed(FRIENDS_KEY, JSON.stringify([tara, { id: "f2" }]));
    const store = new FriendStore();
    await store.ready;
    expect(store.getFriends()).toEqual([tara]);
    expect(store.getFriends()).toBe(store.getFriends());
  });
});

describe("invitationActive", () => {
  const time = 1_800_000_000_000;
  const base = invitation({ id: "i1", spotId: "s1", time, createdAt: time - 3600_000 });

  it("ist vor der Anker-Zeit aktiv", () => {
    expect(invitationActive(base, time - 60_000)).toBe(true);
  });

  it("bleibt bis kurz vor Anker + LINGER aktiv", () => {
    expect(invitationActive(base, time + INVITATION_LINGER_MS - 1)).toBe(true);
  });

  it("ist ab Anker + LINGER vorbei", () => {
    expect(invitationActive(base, time + INVITATION_LINGER_MS)).toBe(false);
    expect(invitationActive(base, time + INVITATION_LINGER_MS + 1)).toBe(false);
  });

  it("ist abgesagt nie aktiv, auch nicht vor der Zeit", () => {
    expect(invitationActive({ ...base, cancelled: true }, time - 60_000)).toBe(false);
  });
});

describe("InviteStore.activeFor", () => {
  const time = 1_800_000_000_000;

  it("wählt bei mehreren aktiven die neueste", async () => {
    seed(
      INVITES_KEY,
      JSON.stringify([
        invitation({ id: "alt", spotId: "s1", time, createdAt: 100 }),
        invitation({ id: "neu", spotId: "s1", time: time + 60_000, createdAt: 300 }),
        invitation({ id: "mittel", spotId: "s1", time, createdAt: 200 }),
      ]),
    );
    const store = new InviteStore();
    await store.ready;
    expect(store.activeFor("s1", time)?.id).toBe("neu");
  });

  it("ignoriert abgesagte, abgelaufene und fremde Spots", async () => {
    seed(
      INVITES_KEY,
      JSON.stringify([
        invitation({ id: "aktiv", spotId: "s1", time, createdAt: 100 }),
        invitation({ id: "abgesagt", spotId: "s1", time, createdAt: 900, cancelled: true }),
        invitation({ id: "alt", spotId: "s1", time: time - INVITATION_LINGER_MS, createdAt: 800 }),
        invitation({ id: "fremd", spotId: "s2", time, createdAt: 999 }),
      ]),
    );
    const store = new InviteStore();
    await store.ready;
    expect(store.activeFor("s1", time)?.id).toBe("aktiv");
    expect(store.activeFor("s2", time)?.id).toBe("fremd");
    expect(store.activeFor("s3", time)).toBeNull();
  });

  it("liefert null, wenn nur Vergangenes existiert", async () => {
    seed(INVITES_KEY, JSON.stringify([invitation({ id: "i1", spotId: "s1", time })]));
    const store = new InviteStore();
    await store.ready;
    expect(store.activeFor("s1", time + INVITATION_LINGER_MS)).toBeNull();
  });
});

describe("InviteStore Mutationen", () => {
  const time = 1_800_000_000_000;
  const tara: Reply = { participantId: "f1", status: "in", arrivalTime: time + 3600_000 };
  const marcel: Reply = { participantId: "f2", status: "in" };

  it("invite legt eine aktive Einladung an und persistiert sie", async () => {
    const writer = new InviteStore();
    await writer.ready;
    const inv = await writer.invite("s1", time);

    expect(inv.cancelled).toBe(false);
    expect(inv.replies).toEqual([]);
    expect(stored(INVITES_KEY)).toBeDefined();

    const reader = new InviteStore();
    await reader.ready;
    expect(reader.activeFor("s1", time)).toEqual(inv);
  });

  it("cancel beendet die Einladung — der Spot bleibt unberührt", async () => {
    const store = new InviteStore();
    await store.ready;
    const inv = await store.invite("s1", time);
    await store.cancel(inv.id);

    expect(store.activeFor("s1", time)).toBeNull();
    const reader = new InviteStore();
    await reader.ready;
    expect(reader.getInvitations()[0].cancelled).toBe(true);
  });

  it("setReply macht ein Upsert pro participantId", async () => {
    const store = new InviteStore();
    await store.ready;
    const inv = await store.invite("s1", time);

    await store.setReply(inv.id, tara);
    await store.setReply(inv.id, marcel);
    await store.setReply(inv.id, { participantId: "f1", status: "out" });

    const replies = store.getInvitations()[0].replies;
    expect(replies).toHaveLength(2);
    expect(replies[0]).toEqual({ participantId: "f1", status: "out" });
    expect(replies[1]).toEqual(marcel);

    const reader = new InviteStore();
    await reader.ready;
    expect(reader.getInvitations()[0].replies).toEqual(replies);
  });

  it("changeTime verschiebt nur den Anker — Antworten bleiben unverändert", async () => {
    const store = new InviteStore();
    await store.ready;
    const inv = await store.invite("s1", time);
    await store.setReply(inv.id, tara);
    await store.setReply(inv.id, marcel);

    await store.changeTime(inv.id, time + 1800_000);

    const after = store.getInvitations()[0];
    expect(after.time).toBe(time + 1800_000);
    expect(after.replies).toEqual([tara, marcel]);

    const reader = new InviteStore();
    await reader.ready;
    expect(reader.getInvitations()[0].replies).toEqual([tara, marcel]);
  });

  it("meldet eine unbekannte id und bleibt danach benutzbar", async () => {
    const store = new InviteStore();
    await store.ready;
    await expect(store.setReply("gibt-es-nicht", tara)).rejects.toThrow(/gibt-es-nicht/);
    await expect(store.changeTime("gibt-es-nicht", time)).rejects.toThrow();
    await expect(store.cancel("gibt-es-nicht")).rejects.toThrow();

    const inv = await store.invite("s1", time);
    expect(store.activeFor("s1", time)?.id).toBe(inv.id);
  });

  it("verwirft kaputte Antworten, nicht die ganze Einladung", async () => {
    seed(
      INVITES_KEY,
      JSON.stringify([
        invitation({
          id: "i1",
          spotId: "s1",
          time,
          replies: [tara, { participantId: "f3" }, { status: "in" }] as Reply[],
        }),
      ]),
    );
    const store = new InviteStore();
    await store.ready;
    const inv = store.activeFor("s1", time);
    expect(inv?.id).toBe("i1");
    expect(inv?.replies).toEqual([tara]);
  });

  it("hält den Einladungs-Snapshot referenzstabil bis zur Mutation", async () => {
    const store = new InviteStore();
    await store.ready;
    const before = store.getInvitations();
    expect(store.getInvitations()).toBe(before);

    await store.invite("s1", time);
    expect(store.getInvitations()).not.toBe(before);
    expect(store.getInvitations()).toBe(store.getInvitations());
  });
});
