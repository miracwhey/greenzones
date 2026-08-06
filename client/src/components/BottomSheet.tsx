import { useEffect, useRef, useState, type ReactNode } from "react";
import { hapticTap } from "../lib/native";

/**
 * Bottom-Sheet mit nativer Geste: Drag am ganzen Sheet, Velocity-Snap
 * zwischen peek/expanded, Rubber-Banding über die Grenzen hinaus.
 */
interface Props {
  peekHeight: number;
  expandedHeight: number;
  children: ReactNode;
}

export default function BottomSheet({ peekHeight, expandedHeight, children }: Props) {
  const [expanded, setExpanded] = useState(false);
  const sheet = useRef<HTMLDivElement>(null);
  const drag = useRef({
    active: false,
    startY: 0,
    startOffset: 0,
    lastY: 0,
    lastT: 0,
    velocity: 0,
  });

  const offsetFor = (isExpanded: boolean) => expandedHeight - (isExpanded ? expandedHeight : peekHeight);

  useEffect(() => {
    const el = sheet.current;
    if (!el) return;

    const setY = (y: number, animate: boolean) => {
      el.style.transition = animate ? "transform 480ms var(--ease-spring)" : "none";
      el.style.transform = `translate3d(0, ${y}px, 0)`;
    };
    setY(offsetFor(expanded), false);

    const onDown = (e: PointerEvent) => {
      // Scrollbaren Inhalt nicht kapern, wenn expanded + Inhalt gescrollt
      const scroller = el.querySelector<HTMLElement>(".sheet-scroll");
      if (expanded && scroller && scroller.scrollTop > 0 && scroller.contains(e.target as Node)) return;
      drag.current = {
        active: true,
        startY: e.clientY,
        startOffset: offsetFor(expanded),
        lastY: e.clientY,
        lastT: performance.now(),
        velocity: 0,
      };
      el.setPointerCapture(e.pointerId);
    };

    const onMove = (e: PointerEvent) => {
      const d = drag.current;
      if (!d.active) return;
      const now = performance.now();
      const dt = now - d.lastT;
      if (dt > 0) d.velocity = (e.clientY - d.lastY) / dt;
      d.lastY = e.clientY;
      d.lastT = now;

      let y = d.startOffset + (e.clientY - d.startY);
      const min = 0;
      const max = expandedHeight - peekHeight;
      // Rubber-Banding jenseits der Snap-Grenzen
      if (y < min) y = -rubber(-y);
      else if (y > max) y = max + rubber(y - max);
      setY(y, false);
    };

    const onUp = () => {
      const d = drag.current;
      if (!d.active) return;
      d.active = false;
      const current = d.startOffset + (d.lastY - d.startY);
      const mid = (expandedHeight - peekHeight) / 2;
      let next: boolean;
      if (Math.abs(d.velocity) > 0.4) next = d.velocity < 0;
      else next = current < mid;
      if (next !== expanded) hapticTap();
      setExpanded(next);
      setY(offsetFor(next), true);
    };

    el.addEventListener("pointerdown", onDown);
    el.addEventListener("pointermove", onMove);
    el.addEventListener("pointerup", onUp);
    el.addEventListener("pointercancel", onUp);
    return () => {
      el.removeEventListener("pointerdown", onDown);
      el.removeEventListener("pointermove", onMove);
      el.removeEventListener("pointerup", onUp);
      el.removeEventListener("pointercancel", onUp);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [expanded, peekHeight, expandedHeight]);

  return (
    <div
      ref={sheet}
      className="sheet glass"
      style={{ height: expandedHeight, bottom: 0 }}
      data-expanded={expanded}
    >
      <div className="grab" />
      {children}
    </div>
  );
}

function rubber(overshoot: number): number {
  return 40 * (1 - 1 / (overshoot / 60 + 1));
}
