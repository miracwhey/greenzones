/**
 * Static-Render wie friendsSheet.test.tsx (react-dom/server, kein jsdom).
 *
 * Nebeneffekt des Render-Pfads, der hier zum Beweis wird: useZoneStatus setzt
 * seinen Status erst per Effect — im Static-Render bleibt er `null` (unbekannt).
 * Alle CTAs unten rendern also, BEVOR irgendein Zonen-Status existiert.
 * Damit ist gepinnt: Einladen/Teilen hängt nie am Legal-Status (rote Zone
 * blockt nichts), nur am Freunde-/Teilen-Zustand.
 */
import { describe, expect, it, vi } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import type { Friend, Spot } from "../../lib/spots";
import type { ZoneEngine } from "../../lib/zones";

vi.mock("../../lib/native", () => ({ hapticTap: () => {} }));

let friends: Friend[] = [];

vi.mock("../../lib/spots", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../lib/spots")>();
  return {
    ...actual,
    useFriends: () => friends,
    useSpots: () => [],
    useSyncState: () => ({
      status: "available",
      loaded: true,
      displayName: "Leon",
      error: null,
      pendingShares: 0,
    }),
    useActiveInvitation: () => null,
  };
});

const { SpotDetailSheet } = await import("../SpotSheets");

// Effect läuft im Static-Render nie — die Promise darf offen bleiben.
const engine = { status: () => new Promise(() => {}) } as unknown as ZoneEngine;

const TARA: Friend = { id: "f1", name: "Tara", color: "#0A9B8E", friendshipZone: "friend-1" };
const LOKAL: Spot = { id: "s1", name: "Unsere Bank", emoji: "🪑", lng: 9.72, lat: 52.36, createdAt: 1 };
const GETEILT: Spot = { ...LOKAL, zoneName: "spot-s1", ownerId: "me", participantIds: ["f1"] };

function render(spot: Spot): string {
  return renderToStaticMarkup(
    <SpotDetailSheet
      spot={spot}
      engine={engine}
      userPos={null}
      onInvite={() => {}}
      onAddFriend={() => {}}
      onNotice={() => {}}
      onClose={() => {}}
    />,
  );
}

describe("SpotDetailSheet — kein CTA hängt am Zonen-Status", () => {
  it("ohne Freunde: „Freund einladen“ statt Sackgasse", () => {
    friends = [];
    const html = render(LOKAL);
    expect(html).toContain("Freund einladen");
    expect(html).toContain("Noch keine Freunde");
    expect(html).not.toContain("Mit Freunden teilen");
  });

  it("mit Freunden, Spot lokal: „Mit Freunden teilen“, kein Freund-einladen-CTA", () => {
    friends = [TARA];
    const html = render(LOKAL);
    expect(html).toContain("Mit Freunden teilen");
    expect(html).not.toContain("Freund einladen");
  });

  it("geteilter Spot: „Einladen“ ist da", () => {
    friends = [TARA];
    const html = render(GETEILT);
    expect(html).toContain(">Einladen<");
  });
});
