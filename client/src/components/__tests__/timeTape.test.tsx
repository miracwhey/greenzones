/**
 * Ohne jsdom im Projekt (keine DOM-Test-Deps) rendert dieser Test die
 * Komponente über react-dom/server zu statischem Markup — das prüft den echten
 * Render-Pfad (Ticks, Readout, Anker, Referenz-Flagge). Die Zeig-/Snap-Logik
 * selbst liegt als pure Funktion in lib/spots/timeFmt und wird dort geprüft.
 */
import { describe, expect, it, vi } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import TimeTape from "../TimeTape";
import { resolveTapeDrag, tapeAnchors } from "../../lib/spots/timeFmt";

// Capacitor-Haptik hat im Node-Lauf nichts zu suchen.
vi.mock("../../lib/native", () => ({ hapticTap: () => {} }));

function at(y: number, mo: number, d: number, h: number, mi = 0): number {
  return new Date(y, mo - 1, d, h, mi).getTime();
}

const BASE = at(2026, 8, 6, 17, 41);

function render(props: Partial<Parameters<typeof TimeTape>[0]> = {}) {
  return renderToStaticMarkup(
    <TimeTape value={props.value ?? BASE} onChange={props.onChange ?? (() => {})} minTime={BASE} {...props} />,
  );
}

describe("TimeTape — Render", () => {
  it("zeigt in der Rastzone 'Jetzt / direkt los'", () => {
    const html = render({ value: BASE });
    expect(html).toContain("Jetzt");
    expect(html).toContain("direkt los");
  });

  it("zeigt Tageswort, Uhrzeit und Relativzeile", () => {
    const html = render({ value: at(2026, 8, 6, 20, 0) });
    expect(html).toContain("Heute · 20:00");
    expect(html).toContain("in 2 Std 19 Min");
  });

  it("verschiebt den Track um 48 px pro Stunde", () => {
    const html = render({ value: at(2026, 8, 6, 18, 41) });
    expect(html).toContain("translateX(-48px)");
  });

  it("setzt Ticks auf absolute Viertelstunden und Stundenmarken", () => {
    const html = render();
    // Erste Tick-Marke: 17:45, also 4 Min = 3.2 px nach dem Cursor.
    expect(html).toContain("left:3.2px");
    // 17:45 … 5:30 (Bandende 5:41) = 144 Viertelstunden-Marken, davon 36 volle Stunden.
    expect(html.match(/class="tt-tick[ "]/g)?.length).toBe(144);
    expect(html.match(/tt-tick-hour/g)?.length).toBe(36);
  });

  it("gibt Mitternacht eine Tages-Pille", () => {
    const html = render();
    expect(html).toContain('class="tt-day-label"');
    expect(html).toContain("Morgen");
    expect(html).toContain("Übermorgen");
  });

  it("blendet die Referenz-Flagge erst ab 15 Min Abstand ein", () => {
    const ref = at(2026, 8, 6, 20, 0);
    const near = render({ value: at(2026, 8, 6, 20, 0), refTime: ref, refLabel: "Leon ab" });
    expect(near).toContain("Leon ab 20:00");
    expect(near).toContain("opacity:0");

    const edge = render({ value: at(2026, 8, 6, 20, 15), refTime: ref, refLabel: "Leon ab" });
    expect(edge).toContain("opacity:1");

    const dflt = render({ value: at(2026, 8, 6, 21, 0), refTime: ref });
    expect(dflt).toContain("bisher 20:00");
  });

  it("zeigt ohne refTime keine Flagge", () => {
    expect(render()).not.toContain("tt-ref-flag");
  });

  it("blendet die Legal-Zeile bei null aus", () => {
    expect(render({ legalLine: () => "Am Spot jetzt erlaubt" })).toContain("Am Spot jetzt erlaubt");
    expect(render({ legalLine: () => null })).not.toContain("tt-legal");
    expect(render()).not.toContain("tt-legal");
  });

  it("übergibt der Legal-Zeile die angezeigte Zeit", () => {
    const seen: number[] = [];
    render({
      value: at(2026, 8, 6, 20, 0),
      legalLine: (t) => {
        seen.push(t);
        return null;
      },
    });
    expect(seen).toEqual([at(2026, 8, 6, 20, 0)]);
  });
});

describe("TimeTape — Anker", () => {
  it("rendert die Chips aus tapeAnchors", () => {
    const html = render();
    expect(html).toContain("Heute Abend");
    expect(html).toContain("Morgen Abend");
    expect(html.match(/class="tt-anchor"/g)?.length).toBe(3);
  });

  it("lässt 'Heute Abend' weg, wenn 20:00 vorbei ist", () => {
    const late = at(2026, 8, 6, 21, 0);
    const html = renderToStaticMarkup(<TimeTape value={late} onChange={() => {}} minTime={late} />);
    expect(html).not.toContain("Heute Abend");
    expect(html).toContain("Morgen Abend");
    expect(html.match(/class="tt-anchor"/g)?.length).toBe(2);
  });

  it("Anker-Ziel und Drag-Snap ergeben dieselbe Kontrakt-Zeit", () => {
    const abend = tapeAnchors(BASE).find((a) => a.key === "tonight");
    expect(abend?.time).toBe(at(2026, 8, 6, 20, 0));
    // dieselbe Zeit über den Zieh-Weg: 139 Min ab 17:41
    expect(resolveTapeDrag(BASE, 139)).toBe(abend?.time);
  });
});
