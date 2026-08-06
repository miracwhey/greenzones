/**
 * Ohne jsdom rendert der Test über react-dom/server zu statischem Markup —
 * derselbe Render-Pfad wie in timeTape.test.tsx.
 *
 * Gemockt werden NUR die drei Hooks der Datenschicht; alles andere
 * (friendLabel, SELF_ID, spotSync) kommt echt aus dem Modul, damit die Formen
 * nicht auseinanderlaufen.
 */
import { describe, expect, it, vi } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import type { Friend, Spot, SyncState } from "../../lib/spots";

vi.mock("../../lib/native", () => ({ hapticTap: () => {} }));

const state: SyncState = {
  status: "unknown",
  loaded: false,
  displayName: "",
  error: null,
  pendingShares: 0,
};
let friends: Friend[] = [];
let spots: Spot[] = [];

vi.mock("../../lib/spots", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../lib/spots")>();
  return {
    ...actual,
    useFriends: () => friends,
    useSpots: () => spots,
    useSyncState: () => state,
  };
});

const { FriendsSheet } = await import("../SpotSheets");

function render(): string {
  return renderToStaticMarkup(<FriendsSheet onNotice={() => {}} onClose={() => {}} />);
}

const TARA: Friend = { id: "f1", name: "Tara", color: "#0A9B8E", friendshipZone: "friend-1" };
const MARCEL: Friend = { id: "f2", name: "Marcel", color: "#7C5CFF", friendshipZone: "friend-2" };
const BANK: Spot = {
  id: "s1",
  name: "Unsere Bank",
  emoji: "🪑",
  lng: 9.72,
  lat: 52.36,
  createdAt: 1,
  zoneName: "spot-s1",
  ownerId: "me",
  participantIds: ["f1", "f2"],
};
const ECKE: Spot = { ...BANK, id: "s2", name: "Maschsee-Ecke", zoneName: "spot-s2", participantIds: ["f2"] };
const LOKAL: Spot = { id: "s3", name: "Balkon", emoji: "🌳", lng: 9.7, lat: 52.3, createdAt: 2 };

describe("FriendsSheet", () => {
  it("zeigt die Freundesliste mit echten gemeinsamen Spots (mockup/community.html)", () => {
    friends = [MARCEL, TARA];
    spots = [BANK, ECKE, LOKAL];
    const html = render();

    expect(html).toContain("Freunde");
    expect(html).toContain("2 Freunde · 2 gemeinsame Spots");
    expect(html).toContain("2 gemeinsame Spots · Unsere Bank, Maschsee-Ecke");
    expect(html).toContain("1 gemeinsamer Spot · Unsere Bank");
    expect(html).toContain("Freund hinzufügen — Link teilen");
    // Der rein lokale Spot taucht in keiner Zeile auf — er ist niemandes gemeinsamer.
    expect(html).not.toContain("Balkon");
  });

  it("bleibt ohne Freunde ruhig und einladend", () => {
    friends = [];
    spots = [];
    const html = render();
    expect(html).toContain("Noch niemand");
    expect(html).toContain("Freund hinzufügen — Link teilen");
  });

  it("zeigt bei fehlendem iCloud-Konto den Contract-Hinweis, ohne die App zu blockieren", () => {
    friends = [];
    spots = [LOKAL];
    state.status = "noAccount";
    const html = render();

    expect(html).toContain("Für Freunde &amp; geteilte Spots bei iCloud anmelden");
    expect(html).toContain("Einstellungen → [dein Name]");
    // Kein Modal, kein Zwang: das Sheet lässt sich schließen und der Link-Button bleibt.
    expect(html).toContain("Schließen");
    state.status = "unknown";
  });

  it("zeigt bei vorhandenem Konto keinen Hinweis", () => {
    friends = [TARA];
    spots = [];
    state.status = "available";
    const html = render();
    expect(html).not.toContain("bei iCloud anmelden");
    state.status = "unknown";
  });
});
