import type { ZoneStatus } from "../lib/zones";
import { pedestrianBanActive, pedestrianHint } from "../lib/time";

function fmtDist(m: number): string {
  if (m === 0) return "hier";
  return m >= 1000 ? (m / 1000).toFixed(1).replace(".", ",") + " km" : Math.round(m) + " m";
}

export default function ZoneList({ status }: { status: ZoneStatus | null }) {
  if (!status) return <div className="empty">Zonen werden geladen …</div>;

  const rows: { cls: "ban" | "time"; dist: number; title: string; badge?: string; subtitle: string; icon: string }[] = [];

  if (Number.isFinite(status.ban.nearestM)) {
    rows.push({
      cls: "ban",
      dist: status.ban.nearestM,
      title: "Verbotszone",
      subtitle: "Schule, Kita, Spielplatz o. Sportstätte · 100 m · ganztägig",
      icon: "M4 10h16v9H4zM8 10V7a4 4 0 0 1 8 0v3",
    });
  }
  if (Number.isFinite(status.time.nearestM)) {
    rows.push({
      cls: "time",
      dist: status.time.nearestM,
      title: "Fußgängerzone",
      badge: pedestrianBanActive() ? "JETZT VERBOTEN" : undefined,
      subtitle: `Verboten 7–20 Uhr · ${pedestrianHint()}`,
      icon: "M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17zM12 7.5V12l3 2",
    });
  }
  rows.sort((a, b) => a.dist - b.dist);

  if (!rows.length) {
    return <div className="empty">Keine Verbotszonen im Umkreis von 2 km. </div>;
  }

  return (
    <>
      {rows.map((r) => (
        <div className="zone-row" key={r.cls}>
          <div className={`zone-ico ${r.cls}`}>
            <svg viewBox="0 0 24 24">
              <path d={r.icon} />
            </svg>
          </div>
          <div className="zone-body">
            <b>
              {r.title}
              {r.badge && <span className="badge-live">{r.badge}</span>}
            </b>
            <span>{r.subtitle}</span>
          </div>
          <div className="zone-dist">{fmtDist(r.dist)}</div>
        </div>
      ))}
    </>
  );
}
