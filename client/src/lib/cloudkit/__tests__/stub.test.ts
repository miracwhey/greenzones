/**
 * Der Web-/Dev-Stub muss den Zustand „kein CloudKit" DEFINIERT abbilden:
 * lesbar leer, schreibend abweisend. Ein Fake-Erfolg hier wäre der teuerste
 * Bug des Layers — er sähe im Browser aus wie ein funktionierender Sync.
 */
import { describe, expect, it } from "vitest";
import { CloudKitSync, cloudError, cloudErrorCode, cloudMessage, emptySnapshot } from "..";

describe("CloudKitSync — Web-Stub", () => {
  it("meldet couldNotDetermine statt eines Kontos", async () => {
    await expect(CloudKitSync.getAccountStatus()).resolves.toEqual({
      status: "couldNotDetermine",
    });
  });

  it("liefert einen leeren Snapshot mit Status — kein Reject", async () => {
    await expect(CloudKitSync.fetchAll()).resolves.toEqual({
      status: "couldNotDetermine",
      userID: "",
      friends: [],
      spots: [],
      invitations: [],
    });
  });

  it("weist jeden Schreibversuch mit code noAccount ab", async () => {
    const writes: Promise<unknown>[] = [
      CloudKitSync.createFriendInvite({ displayName: "Leon", emoji: "🌿" }),
      CloudKitSync.acceptShare({ url: "https://www.icloud.com/share/x", displayName: "Leon", emoji: "" }),
      CloudKitSync.setProfile({ name: "Leon", emoji: "🌿" }),
      CloudKitSync.createSpotShare({
        id: "s1",
        name: "Unsere Bank",
        emoji: "🪑",
        lng: 9.7,
        lat: 52.3,
        createdAt: 1,
      }),
      CloudKitSync.offerSpotToFriends({
        zoneName: "spot-s1",
        shareURL: "https://www.icloud.com/share/x",
        spotName: "Unsere Bank",
        spotEmoji: "🪑",
        friendshipZones: ["friend-1"],
      }),
      CloudKitSync.deleteSpot({ zoneName: "spot-s1" }),
      CloudKitSync.saveInvitation({
        spotZone: "spot-s1",
        id: "i1",
        time: 1,
        createdAt: 1,
        cancelled: false,
      }),
      CloudKitSync.saveReply({ spotZone: "spot-s1", invitationId: "i1", status: "in" }),
      CloudKitSync.registerSubscriptions(),
    ];
    for (const write of writes) {
      await expect(write).rejects.toMatchObject({ code: "noAccount" });
    }
  });

  it("gibt ein entfernbares Listener-Handle zurück, das nie feuert", async () => {
    let fired = 0;
    const handle = await CloudKitSync.addListener("cloudChanged", () => {
      fired++;
    });
    await handle.remove();
    expect(fired).toBe(0);
  });
});

describe("Fehler-Semantik", () => {
  it("erkennt nur die Codes des Contracts", () => {
    expect(cloudErrorCode(cloudError("network", "x"))).toBe("network");
    expect(cloudErrorCode(new Error("irgendwas"))).toBeNull();
    expect(cloudErrorCode(Object.assign(new Error("x"), { code: "erfunden" }))).toBeNull();
    expect(cloudErrorCode(null)).toBeNull();
  });

  it("nennt Netz und Konto, nie den Nutzer", () => {
    expect(cloudMessage(cloudError("network", "x"))).toContain("Kein Netz");
    expect(cloudMessage(cloudError("noAccount", "x"))).toContain("iCloud");
    expect(cloudMessage(new Error("x"))).toBe("Hat nicht geklappt — nichts wurde gesendet.");
  });

  it("emptySnapshot trägt den Status und sonst nichts", () => {
    expect(emptySnapshot("restricted")).toEqual({
      status: "restricted",
      userID: "",
      friends: [],
      spots: [],
      invitations: [],
    });
  });
});
