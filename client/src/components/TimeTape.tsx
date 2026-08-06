/**
 * Zeit-Band-Picker („TimeTape") — Port des abgenommenen Mockups
 * (mockup/invite.html, .timepick/.tape/…). Das Band läuft unter einem festen
 * Cursor in der Mitte durch, gesnappt wird auf absolute Viertelstunden.
 *
 * Controlled: `value` (epoch ms) gehört dem Aufrufer; während des Ziehens hält
 * die Komponente einen internen, ungesnappten Zustand und meldet erst beim
 * Loslassen bzw. beim Anker-Tap über `onChange`.
 */
import { useMemo, useRef, useState, type PointerEvent as ReactPointerEvent, type ReactElement } from "react";
import {
  MIN_MS,
  NOW_ZONE_MIN,
  QUARTER_MS,
  QUARTER_MIN,
  TAPE_RANGE_MIN,
  TAPE_RANGE_MS,
  ceilToQuarter,
  dayWord,
  fmtClock,
  relWord,
  resolveTapeDrag,
  tapeAnchors,
} from "../lib/spots/timeFmt";
import { hapticTap } from "../lib/native";
import "./TimeTape.css";

/** Band-Maßstab: 48 px pro Stunde. */
const PX_PER_MIN = 48 / 60;

interface TimeTapeProps {
  /** Gewählte Zeit (epoch ms, gesnappt). */
  value: number;
  /** Feuert beim Snap nach dem Ziehen und beim Anker-Tap — nicht pro Move-Pixel. */
  onChange: (v: number) => void;
  /** Referenzzeit für die Flagge im Band (z. B. die bisherige Zeit). */
  refTime?: number;
  /** Text vor der Referenz-Uhrzeit, z. B. "Leon ab". */
  refLabel?: string;
  /** Bandanfang; ohne Angabe der Zeitpunkt des Mounts. */
  minTime?: number;
  /** Status-Zeile unterm Band; `null` blendet die Zeile aus. */
  legalLine?: (t: number) => string | null;
}

function clamp(v: number, lo: number, hi: number): number {
  return Math.min(Math.max(v, lo), hi);
}

export default function TimeTape({ value, onChange, refTime, refLabel, minTime, legalLine }: TimeTapeProps) {
  // „Jetzt" einmal beim Mount einfrieren — sonst wandert das Band unter dem Finger.
  const [mountedAt] = useState(() => Date.now());
  const base = minTime ?? mountedAt;

  const [dragMin, setDragMin] = useState<number | null>(null);
  const dragRef = useRef<{ startX: number; startMin: number } | null>(null);

  const valueMin = clamp((value - base) / MIN_MS, 0, TAPE_RANGE_MIN);
  const curMin = dragMin ?? valueMin;
  const curMs = base + curMin * MIN_MS;
  const inNowZone = curMin < NOW_ZONE_MIN;

  // Ticks liegen auf absoluten Viertelstunden, nicht auf „base + k·15".
  const ticks = useMemo(() => {
    const out: ReactElement[] = [];
    const end = base + TAPE_RANGE_MS;
    for (let t = ceilToQuarter(base); t <= end; t += QUARTER_MS) {
      const x = ((t - base) / MIN_MS) * PX_PER_MIN;
      const d = new Date(t);
      const isHour = d.getMinutes() === 0;
      out.push(<div key={`t${t}`} className={isHour ? "tt-tick tt-tick-hour" : "tt-tick"} style={{ left: x }} />);
      if (isHour) {
        out.push(
          <div key={`l${t}`} className="tt-tick-label" style={{ left: x }}>
            {d.getHours()}
          </div>,
        );
        if (d.getHours() === 0) {
          out.push(
            <div key={`d${t}`} className="tt-day-label" style={{ left: x }}>
              {dayWord(t, base)}
            </div>,
          );
        }
      }
    }
    return out;
  }, [base]);

  const anchors = useMemo(() => tapeAnchors(base), [base]);

  function commit(t: number) {
    if (t === value) return;
    hapticTap();
    onChange(t);
  }

  function onPointerDown(e: ReactPointerEvent<HTMLDivElement>) {
    e.currentTarget.setPointerCapture(e.pointerId);
    dragRef.current = { startX: e.clientX, startMin: valueMin };
    setDragMin(valueMin);
  }

  function onPointerMove(e: ReactPointerEvent<HTMLDivElement>) {
    const d = dragRef.current;
    if (!d) return;
    setDragMin(clamp(d.startMin - (e.clientX - d.startX) / PX_PER_MIN, 0, TAPE_RANGE_MIN));
  }

  function onPointerUp() {
    const d = dragRef.current;
    if (!d) return;
    dragRef.current = null;
    const released = dragMin ?? d.startMin;
    setDragMin(null);
    commit(resolveTapeDrag(base, released));
  }

  const legal = legalLine ? legalLine(curMs) : null;
  const refVisible = refTime !== undefined && Math.abs(curMs - refTime) >= QUARTER_MIN * MIN_MS;

  return (
    <div className="tt">
      <div className="tt-readout">
        <b>{inNowZone ? "Jetzt" : `${dayWord(curMs, base)} · ${fmtClock(curMs)}`}</b>
        <span className="tt-rel">{inNowZone ? "direkt los" : relWord(curMs, base)}</span>
      </div>

      <div
        className="tt-tape"
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={onPointerUp}
      >
        <div
          className={dragMin === null ? "tt-track tt-animate" : "tt-track"}
          style={{ transform: `translateX(${-curMin * PX_PER_MIN}px)` }}
        >
          {ticks}
          {refTime !== undefined && (
            <div
              className="tt-ref-flag"
              style={{ left: ((refTime - base) / MIN_MS) * PX_PER_MIN, opacity: refVisible ? 1 : 0 }}
            >
              {`${refLabel ?? "bisher"} ${fmtClock(refTime)}`}
            </div>
          )}
        </div>
        <div className="tt-needle" />
      </div>

      <div className="tt-anchors">
        {anchors.map((a) => (
          <button key={a.key} type="button" className="tt-anchor" onClick={() => commit(a.time)}>
            {a.label}
          </button>
        ))}
      </div>

      {legal !== null && (
        <div className="tt-legal">
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path d="M4.5 12.5l5 5 10-11" />
          </svg>
          <span>{legal}</span>
        </div>
      )}
    </div>
  );
}
