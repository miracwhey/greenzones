import { useEffect, useRef, useState } from "react";
import type { ZoneStatus } from "../lib/zones";
import type { Result } from "../lib/search";
import { formatDistanceM } from "../lib/geo";
import { pedestrianBanActive } from "../lib/time";
import { hapticStatus, hapticTap } from "../lib/native";
import ZoneList from "./ZoneList";

export type StatusKind = "ok" | "ban" | "time" | "wait";

export function statusKind(status: ZoneStatus | null): StatusKind {
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

export default function StatusBar({ status, locating, target, onClearTarget }: Props) {
  const kind = statusKind(status);
  const prev = useRef<StatusKind>("wait");
  const [open, setOpen] = useState(false);

  useEffect(() => {
    if (kind === prev.current || kind === "wait") return;
    hapticStatus(kind === "ok" ? "ok" : "warn");
    prev.current = kind;
  }, [kind]);

  let title = "Standort wird ermittelt …";
  let sub = " ";

  if (target) {
    title = !status ? "Ziel wird geprüft …" : kind === "ok" ? "Am Ziel erlaubt" : "Am Ziel verboten";
    sub = targetSub(target);
  } else if (!locating && status) {
    if (kind === "ban") {
      title = "Hier verboten";
      sub = "Verbotszone · ganztägig";
    } else if (kind === "time") {
      title = "Jetzt verboten";
      sub = "Fußgängerzone · frei ab 20:00";
    } else {
      title = "Hier erlaubt";
      const parts: string[] = [];
      if (Number.isFinite(status.ban.nearestM)) {
        parts.push(`Verbotszone ${formatDistanceM(status.ban.nearestM)}`);
      }
      if (Number.isFinite(status.time.nearestM)) {
        parts.push(`Fußgängerzone ${formatDistanceM(status.time.nearestM)}`);
      }
      sub = parts.length ? parts.join(" · ") : "Keine Verbotszone im Umkreis von 2 km";
    }
  }

  return (
    <>
      {!open && (
        <div
          className={`bar glass s-${kind}`}
          role="button"
          aria-label="Zonen-Details öffnen"
          onClick={() => {
            hapticTap();
            setOpen(true);
          }}
        >
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
              className="bar-close"
              aria-label="Ziel verlassen"
              data-testid="target-close"
              onPointerDown={(e) => {
                e.stopPropagation();
                onClearTarget();
              }}
              onClick={(e) => e.stopPropagation()}
            >
              <svg viewBox="0 0 24 24">
                <path d="M6 6l12 12M18 6L6 18" />
              </svg>
            </button>
          )}
          <div className="chev">
            <svg viewBox="0 0 24 24">
              <path d="m6 14 6-6 6 6" />
            </svg>
          </div>
        </div>
      )}

      {open && (
        <div className="detail-backdrop" onClick={() => setOpen(false)}>
          <div className="detail glass" onClick={(e) => e.stopPropagation()}>
            <div className="grab" />
            <div className={`detail-status s-${kind}`}>
              <div className="dot">
                <svg className="ic-check" viewBox="0 0 24 24">
                  <path d="M4.5 12.5l5 5 10-11" />
                </svg>
                <svg className="ic-x" viewBox="0 0 24 24">
                  <path d="M6 6l12 12M18 6L6 18" />
                </svg>
                <div className="ic-spin" />
              </div>
              <div className="txt">
                <b>{title}</b>
                <span>{target ? targetSub(target) : "Dein Standort"}</span>
              </div>
              <button
                type="button"
                className="bar-close detail-close"
                aria-label="Details schließen"
                onClick={() => setOpen(false)}
              >
                <svg viewBox="0 0 24 24">
                  <path d="M6 6l12 12M18 6L6 18" />
                </svg>
              </button>
            </div>
            <ZoneList status={status} />
            <p className="sheet-foot">Umkreis 2 km · Daten © OpenStreetMap · keine Rechtsberatung</p>
          </div>
        </div>
      )}
    </>
  );
}
