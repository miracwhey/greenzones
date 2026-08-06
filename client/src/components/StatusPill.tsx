import { useEffect, useRef } from "react";
import type { ZoneStatus } from "../lib/zones";
import type { Result } from "../lib/search";
import { formatDistanceM } from "../lib/geo";
import { pedestrianBanActive } from "../lib/time";
import { hapticStatus } from "../lib/native";

export type PillKind = "ok" | "ban" | "time" | "wait";

export function pillKind(status: ZoneStatus | null): PillKind {
  if (!status) return "wait";
  if (status.ban.inside) return "ban";
  if (status.time.inside && pedestrianBanActive()) return "time";
  return "ok";
}

/**
 * Kontext-Zeile des Ziels: "Linden-Mitte · Hannover".
 * Ein Offline-Treffer trägt sein Detail als "Typ · Kontext" — im Ziel-Modus ist
 * der Typ redundant (der Name steht ja nicht daneben), der Kontext nicht.
 * Photon-Treffer haben kein Typ-Präfix, ihre Detail-Zeile bleibt wie sie ist.
 */
function targetSub(result: Result): string {
  if (result.source === "photon") return result.detail || result.name;
  const context = result.detail.split(" · ").slice(1).join(" · ");
  return context ? `${result.name} · ${context}` : result.name;
}

interface Props {
  status: ZoneStatus | null;
  locating: boolean;
  /** Gesetzt = Ziel-Modus: der Status gilt fürs Ziel, nicht für den Standort. */
  target: Result | null;
  onClearTarget: () => void;
}

export default function StatusPill({ status, locating, target, onClearTarget }: Props) {
  const kind = pillKind(status);
  const prev = useRef<PillKind>("wait");

  useEffect(() => {
    if (kind === prev.current || kind === "wait") return;
    hapticStatus(kind === "ok" ? "ok" : "warn");
    prev.current = kind;
  }, [kind]);

  let title = "Standort wird ermittelt …";
  let sub = " ";

  if (target) {
    if (!status) {
      title = "Ziel wird geprüft …";
      sub = targetSub(target);
    } else {
      title = kind === "ok" ? "Am Ziel erlaubt" : "Am Ziel verboten";
      sub = targetSub(target);
    }
  } else if (!locating && status) {
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
        ? `Nächste Verbotszone in ${formatDistanceM(Math.min(...cands))}`
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
        {target && (
          <button
            type="button"
            className="pill-close"
            aria-label="Ziel verlassen"
            data-testid="target-close"
            onPointerDown={onClearTarget}
          >
            <svg viewBox="0 0 24 24">
              <path d="M6 6l12 12M18 6L6 18" />
            </svg>
          </button>
        )}
      </div>
    </div>
  );
}
