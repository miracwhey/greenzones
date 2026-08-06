import { describe, expect, it } from "vitest";
import {
  ceilToQuarter,
  dayWord,
  fmtClock,
  relWord,
  resolveTapeDrag,
  snapToQuarter,
  spotAllowedAt,
  tapeAnchors,
} from "../timeFmt";
import { pedestrianBanAtHour } from "../../time";
import type { ZoneStatus } from "../../zones";

/** Lokale Zeit — Tests laufen zeitzonenunabhängig, weil überall lokal gerechnet wird. */
function at(y: number, mo: number, d: number, h: number, mi = 0, s = 0, ms = 0): number {
  return new Date(y, mo - 1, d, h, mi, s, ms).getTime();
}

function zone(ban: boolean, time: boolean): ZoneStatus {
  return {
    ban: { inside: ban, nearestM: ban ? 0 : 500 },
    time: { inside: time, nearestM: time ? 0 : 500 },
  };
}

describe("fmtClock", () => {
  it("schreibt Minuten zweistellig, Stunde ohne führende Null", () => {
    expect(fmtClock(at(2026, 8, 6, 20, 0))).toBe("20:00");
    expect(fmtClock(at(2026, 8, 6, 9, 5))).toBe("9:05");
    expect(fmtClock(at(2026, 8, 6, 0, 0))).toBe("0:00");
  });
});

describe("snapToQuarter", () => {
  it("rundet auf die nächstliegende absolute Viertelstunde", () => {
    expect(fmtClock(snapToQuarter(at(2026, 8, 6, 17, 7, 29)))).toBe("17:00");
    expect(fmtClock(snapToQuarter(at(2026, 8, 6, 17, 7, 30)))).toBe("17:15");
    expect(fmtClock(snapToQuarter(at(2026, 8, 6, 17, 22, 30)))).toBe("17:30");
    expect(fmtClock(snapToQuarter(at(2026, 8, 6, 17, 41)))).toBe("17:45");
  });

  it("lässt eine exakte Viertelstunde stehen und nullt Sekunden", () => {
    expect(snapToQuarter(at(2026, 8, 6, 17, 15))).toBe(at(2026, 8, 6, 17, 15));
    expect(snapToQuarter(at(2026, 8, 6, 17, 15, 4, 250))).toBe(at(2026, 8, 6, 17, 15));
  });

  it("rollt über die volle Stunde", () => {
    expect(snapToQuarter(at(2026, 8, 6, 17, 53))).toBe(at(2026, 8, 6, 18, 0));
    expect(snapToQuarter(at(2026, 8, 6, 23, 55))).toBe(at(2026, 8, 7, 0, 0));
  });

  it("ist absolut, nicht relativ zu einem Startpunkt", () => {
    // 'minTime + k·15' ergäbe 17:56 — verlangt ist die runde Uhrzeit.
    const base = at(2026, 8, 6, 17, 41);
    expect(fmtClock(snapToQuarter(base + 15 * 60_000))).toBe("18:00");
  });
});

describe("ceilToQuarter", () => {
  it("liefert die nächste Viertelstunde, exakte bleibt stehen", () => {
    expect(ceilToQuarter(at(2026, 8, 6, 17, 41))).toBe(at(2026, 8, 6, 17, 45));
    expect(ceilToQuarter(at(2026, 8, 6, 17, 45))).toBe(at(2026, 8, 6, 17, 45));
    expect(ceilToQuarter(at(2026, 8, 6, 17, 45, 0, 1))).toBe(at(2026, 8, 6, 18, 0));
  });
});

describe("dayWord", () => {
  const now = at(2026, 8, 6, 23, 50);

  it("wechselt an Mitternacht, nicht nach 24 h", () => {
    expect(dayWord(at(2026, 8, 6, 23, 59), now)).toBe("Heute");
    expect(dayWord(at(2026, 8, 7, 0, 10), now)).toBe("Morgen");
    expect(dayWord(at(2026, 8, 7, 23, 0), now)).toBe("Morgen");
    expect(dayWord(at(2026, 8, 8, 0, 5), now)).toBe("Übermorgen");
  });

  it("nennt Vergangenes 'Heute'", () => {
    expect(dayWord(at(2026, 8, 5, 12, 0), now)).toBe("Heute");
  });
});

describe("relWord", () => {
  const now = at(2026, 8, 6, 17, 41);

  it("kennt alle vier Formen", () => {
    expect(relWord(now, now)).toBe("direkt los");
    expect(relWord(now + 20_000, now)).toBe("direkt los");
    expect(relWord(at(2026, 8, 6, 18, 6), now)).toBe("in 25 Min");
    expect(relWord(at(2026, 8, 6, 19, 41), now)).toBe("in 2 Std");
    expect(relWord(at(2026, 8, 6, 20, 0), now)).toBe("in 2 Std 19 Min");
  });
});

describe("resolveTapeDrag", () => {
  const base = at(2026, 8, 6, 17, 41);

  it("rastet unter 8 Min auf 'Jetzt'", () => {
    expect(resolveTapeDrag(base, 0)).toBe(base);
    expect(resolveTapeDrag(base, 7.9)).toBe(base);
  });

  it("snappt ab 8 Min auf die absolute Viertelstunde", () => {
    expect(resolveTapeDrag(base, 8)).toBe(at(2026, 8, 6, 17, 45));
    expect(resolveTapeDrag(base, 139)).toBe(at(2026, 8, 6, 20, 0));
  });

  it("bleibt im Band [minTime, +36 h]", () => {
    const end = base + 36 * 60 * 60_000;
    expect(resolveTapeDrag(base, -5)).toBe(base);
    // 5:41 snappte auf 5:45 — das läge hinter dem Bandende, also gedeckelt.
    expect(resolveTapeDrag(base, 36 * 60)).toBe(end);
    expect(resolveTapeDrag(base, 40 * 60)).toBe(end);
  });
});

describe("tapeAnchors", () => {
  it("zeigt alle drei, solange sie im Band liegen", () => {
    const base = at(2026, 8, 6, 10, 0);
    expect(tapeAnchors(base).map((a) => a.label)).toEqual(["Jetzt", "Heute Abend", "Morgen Abend"]);
    expect(tapeAnchors(base)[1].time).toBe(at(2026, 8, 6, 20, 0));
    expect(tapeAnchors(base)[2].time).toBe(at(2026, 8, 7, 20, 0));
  });

  it("lässt 'Heute Abend' weg, wenn 20:00 vorbei ist", () => {
    expect(tapeAnchors(at(2026, 8, 6, 21, 0)).map((a) => a.label)).toEqual(["Jetzt", "Morgen Abend"]);
    // Punktgenau: 20:00 selbst zählt noch.
    expect(tapeAnchors(at(2026, 8, 6, 20, 0)).map((a) => a.label)).toContain("Heute Abend");
    expect(tapeAnchors(at(2026, 8, 6, 20, 1)).map((a) => a.label)).not.toContain("Heute Abend");
  });

  it("lässt 'Morgen Abend' weg, wenn es aus dem 36-h-Band fällt", () => {
    expect(tapeAnchors(at(2026, 8, 6, 3, 0)).map((a) => a.label)).toEqual(["Jetzt", "Heute Abend"]);
    expect(tapeAnchors(at(2026, 8, 6, 8, 0)).map((a) => a.label)).toContain("Morgen Abend");
  });
});

describe("pedestrianBanAtHour", () => {
  it("gilt 7 bis einschließlich 19 Uhr", () => {
    expect(pedestrianBanAtHour(6)).toBe(false);
    expect(pedestrianBanAtHour(7)).toBe(true);
    expect(pedestrianBanAtHour(19)).toBe(true);
    expect(pedestrianBanAtHour(20)).toBe(false);
    expect(pedestrianBanAtHour(0)).toBe(false);
  });
});

describe("spotAllowedAt", () => {
  it("öffnet die Fußgängerzone erst um 20 Uhr", () => {
    const s = zone(false, true);
    expect(spotAllowedAt(s, new Date(at(2026, 8, 6, 6, 59)))).toBe(true);
    expect(spotAllowedAt(s, new Date(at(2026, 8, 6, 7, 0)))).toBe(false);
    expect(spotAllowedAt(s, new Date(at(2026, 8, 6, 19, 59)))).toBe(false);
    expect(spotAllowedAt(s, new Date(at(2026, 8, 6, 20, 0)))).toBe(true);
  });

  it("das Bann-Polygon schlägt immer durch", () => {
    for (const h of [3, 6, 7, 12, 19, 20, 23]) {
      expect(spotAllowedAt(zone(true, false), new Date(at(2026, 8, 6, h, 0)))).toBe(false);
      expect(spotAllowedAt(zone(true, true), new Date(at(2026, 8, 6, h, 0)))).toBe(false);
    }
  });

  it("außerhalb jeder Zone immer erlaubt", () => {
    for (const h of [0, 7, 13, 19, 20]) {
      expect(spotAllowedAt(zone(false, false), new Date(at(2026, 8, 6, h, 0)))).toBe(true);
    }
  });
});
