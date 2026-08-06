import { useEffect, useRef } from "react";
import type { ZoneStatus } from "../lib/zones";
import { pedestrianBanActive } from "../lib/time";
import { hapticStatus } from "../lib/native";

export type PillKind = "ok" | "ban" | "time" | "wait";

export function pillKind(status: ZoneStatus | null): PillKind {
  if (!status) return "wait";
  if (status.ban.inside) return "ban";
  if (status.time.inside && pedestrianBanActive()) return "time";
  return "ok";
}

function fmtDist(m: number): string {
  return m >= 1000 ? (m / 1000).toFixed(1).replace(".", ",") + " km" : Math.round(m) + " m";
}

interface Props {
  status: ZoneStatus | null;
  locating: boolean;
}

export default function StatusPill({ status, locating }: Props) {
  const kind = pillKind(status);
  const prev = useRef<PillKind>("wait");

  useEffect(() => {
    if (kind === prev.current || kind === "wait") return;
    hapticStatus(kind === "ok" ? "ok" : "warn");
    prev.current = kind;
  }, [kind]);

  let title = "Standort wird ermittelt …";
  let sub = " ";
  if (!locating && status) {
    if (kind === "ban") {
      title = "Hier verboten";
      sub = "Verbotszone · ganztägig";
    } else if (kind === "time") {
      title = "Jetzt verboten";
      sub = "Fußgängerzone · frei ab 20:00";
    } else {
      title = "Hier erlaubt";
      const cands = [status.ban.nearestM, pedestrianBanActive() ? status.time.nearestM : Infinity].filter(
        Number.isFinite,
      );
      sub = cands.length
        ? `Nächste Verbotszone in ${fmtDist(Math.min(...cands))}`
        : "Keine Verbotszone in der Nähe";
    }
  }

  return (
    <div className="top">
      <div className={`pill glass s-${kind}`}>
        <div className="dot">
          <svg className="ic-check" viewBox="0 0 24 24">
            <path d="M4.5 12.5l5 5 10-11" />
          </svg>
          <svg className="ic-x" viewBox="0 0 24 24">
            <path d="M6 6l12 12M18 6L6 18" />
          </svg>
          <div className="ic-spin" />
        </div>
        <div className="txt" key={title}>
          <b>{title}</b>
          <span>{sub}</span>
        </div>
      </div>
    </div>
  );
}
