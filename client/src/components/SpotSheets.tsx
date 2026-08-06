/**
 * Sheets des Community-Features — Port der abgenommenen Mockups
 * mockup/community.html (Spot markieren) und mockup/invite.html
 * (Einladen · Antworten · Verwalten).
 *
 * Konzept v2.2: die Host-Zeit ist ein ANKER, jede Antwort trägt ihren eigenen
 * Zustand. Es gibt keinen Verhandlungs- oder Entscheidungs-Flow — niemandes
 * Zeit stellt sich durch die Antwort eines anderen um.
 *
 * Darstellung kommt über Props (Spot, Engine, Position), der Bestand über die
 * Store-Hooks. Die Sheets liegen im Rahmen aus App.css
 * (.detail-backdrop/.detail/.grab), alles Eigene ist sp-präfixiert.
 */
import { useEffect, useState, type ReactNode } from "react";
import TimeTape from "./TimeTape";
import { statusKind } from "./StatusBar";
import { distanceM, formatDistanceM, type LngLat } from "../lib/geo";
import type { ZoneEngine, ZoneStatus } from "../lib/zones";
import { hapticTap } from "../lib/native";
import {
  inviteStore,
  spotStore,
  useActiveInvitation,
  useFriends,
  type Friend,
  type Invitation,
  type Reply,
  type Spot,
} from "../lib/spots";
// SELF_ID liegt (noch) nicht auf der Fassade — die Datenschicht bleibt unangetastet.
import { SELF_ID } from "../lib/spots/types";
import { MIN_MS, NOW_ZONE_MIN, dayWord, fmtClock, spotAllowedAt } from "../lib/spots/timeFmt";
import "./spots.css";

const EMOJIS = ["🪑", "🌳", "🌊", "🔥", "⭐️", "🏕️"];

// --------------------------------------------------------------- Bausteine

function Sheet({ onClose, children }: { onClose: () => void; children: ReactNode }) {
  return (
    <div className="detail-backdrop" onClick={onClose}>
      <div className="detail glass" onClick={(e) => e.stopPropagation()}>
        <div className="grab" />
        {children}
      </div>
    </div>
  );
}

/** Zonen-Status eines Punktes; `null` solange (oder mangels Punkt) unbekannt. */
function useZoneStatus(engine: ZoneEngine, point: LngLat | null): ZoneStatus | null {
  const [status, setStatus] = useState<ZoneStatus | null>(null);
  const lng = point?.lng;
  const lat = point?.lat;
  useEffect(() => {
    if (lng === undefined || lat === undefined) {
      setStatus(null);
      return;
    }
    let stale = false;
    engine
      .status({ lng, lat })
      .then((s) => {
        if (!stale) setStatus(s);
      })
      .catch(() => {});
    return () => {
      stale = true;
    };
  }, [engine, lng, lat]);
  return status;
}

/** spot-card aus dem Mockup — ohne Stadtteil (dafür gibt es keine Quelle). */
function SpotCard({
  spot,
  status,
  userPos,
}: {
  spot: Spot;
  status: ZoneStatus | null;
  userPos: LngLat | null;
}) {
  const kind = statusKind(status);
  const dist = userPos ? formatDistanceM(distanceM(userPos, spot)) : null;
  return (
    <div className={kind === "ok" ? "sp-card" : "sp-card sp-card-no"}>
      <div className="sp-card-emoji">{spot.emoji}</div>
      <div className="sp-card-body">
        <b>{spot.name}</b>
        <span>
          {kind === "wait" ? (
            <span>Status wird geprüft …</span>
          ) : (
            <span className={kind === "ok" ? "sp-ok" : "sp-no"}>
              {kind === "ok" ? "Erlaubt" : "Verboten"}
            </span>
          )}
          {dist && ` · ${dist} von dir`}
        </span>
      </div>
    </div>
  );
}

function Avatar({ name, color }: { name: string; color: string }) {
  return (
    <span className="sp-ava" style={{ background: color }} aria-hidden="true">
      {name.slice(0, 1).toUpperCase()}
    </span>
  );
}

interface RsvpEntry {
  key: string;
  name: string;
  color: string;
  text: string;
  tone: "in" | "open";
}

/** Antwort → Statuszeile. „Ich komme um 21:00" ist eine Zusage, keine Absage. */
function replyState(reply: Reply | undefined, self: boolean): { text: string; tone: "in" | "open" } {
  if (!reply) return { text: "offen", tone: "open" };
  if (reply.status === "out") return { text: "kann nicht", tone: "open" };
  if (reply.arrivalTime !== undefined) {
    return { text: `${self ? "kommst" : "kommt"} um ${fmtClock(reply.arrivalTime)} ✓`, tone: "in" };
  }
  return { text: "dabei ✓", tone: "in" };
}

/**
 * „Wer kommt": Gastgeber (falls fremd) · Freunde · eigene Antwort. Teilnehmer
 * ohne Antwort stehen auf „offen" — das ist ein Zustand, kein Fehlen.
 */
function rsvpEntries(inv: Invitation, friends: Friend[]): RsvpEntry[] {
  const rows: RsvpEntry[] = [];
  if (inv.hostId !== SELF_ID) {
    const host = friends.find((f) => f.id === inv.hostId);
    rows.push({
      key: `host-${inv.hostId}`,
      name: host?.name ?? "Gastgeber",
      color: host?.color ?? "var(--accent)",
      text: `ab ${fmtClock(inv.time)} · Gastgeber`,
      tone: "in",
    });
  }
  for (const f of friends) {
    if (f.id === inv.hostId) continue;
    const reply = inv.replies.find((r) => r.participantId === f.id);
    rows.push({ key: f.id, name: f.name, color: f.color, ...replyState(reply, false) });
  }
  const own = inv.replies.find((r) => r.participantId === SELF_ID);
  if (own) rows.push({ key: "self", name: "Du", color: "var(--accent)", ...replyState(own, true) });
  // Antworten von Teilnehmern, die (noch) nicht lokal als Freund bekannt sind.
  for (const r of inv.replies) {
    if (r.participantId === SELF_ID || r.participantId === inv.hostId) continue;
    if (friends.some((f) => f.id === r.participantId)) continue;
    rows.push({ key: r.participantId, name: "Freund", color: "var(--ink-3)", ...replyState(r, false) });
  }
  return rows;
}

function RsvpRow({ name, color, text, tone }: Omit<RsvpEntry, "key">) {
  return (
    <div className="sp-rsvp">
      <Avatar name={name} color={color} />
      <span className="sp-who">{name}</span>
      <span className={`sp-st ${tone}`}>{text}</span>
    </div>
  );
}

/**
 * Zeile unterm Band — der Legal-Status kippt mit der gewählten Uhrzeit.
 * In der „Jetzt"-Rastzone steht dort „jetzt", nicht die Uhrzeit: das Band
 * zeigt oben dasselbe.
 */
function legalLineAt(status: ZoneStatus | null, t: number, base: number): string | null {
  if (!status) return null;
  const when = t - base < NOW_ZONE_MIN * MIN_MS ? "jetzt" : `um ${fmtClock(t)}`;
  if (spotAllowedAt(status, new Date(t))) return `Am Spot ${when} erlaubt`;
  if (status.ban.inside) return `Am Spot ${when} verboten — Verbotszone`;
  return `Am Spot ${when} verboten — Fußgängerzone bis 20 Uhr`;
}

/**
 * Band + Legal-Zeile am Spot. Die Warn-Färbung hängt an der Hülle, weil
 * TimeTape unangetastet bleibt (der Text im Band kommt live aus legalLine).
 */
function SpotTape({
  status,
  value,
  onChange,
  refTime,
  refLabel,
  minTime,
}: {
  status: ZoneStatus | null;
  value: number;
  onChange: (v: number) => void;
  refTime?: number;
  refLabel?: string;
  minTime: number;
}) {
  const warn = status !== null && !spotAllowedAt(status, new Date(value));
  return (
    <div className={warn ? "sp-tape-warn" : undefined}>
      <TimeTape
        value={value}
        onChange={onChange}
        refTime={refTime}
        refLabel={refLabel}
        minTime={minTime}
        legalLine={(t) => legalLineAt(status, t, minTime)}
      />
    </div>
  );
}

// ------------------------------------------------------------ Spot markieren

interface NewSpotSheetProps {
  engine: ZoneEngine;
  userPos: LngLat | null;
  /** Kartenmittelpunkt — „Auf Karte wählen" liest ihn beim Bestätigen. */
  getMapCenter: () => LngLat | null;
  /** true = Karte ist freigegeben, das Sheet ist auf die Bestätigungsleiste eingeklappt. */
  picking: boolean;
  onPickStart: () => void;
  onPickEnd: () => void;
  onClose: () => void;
}

export function NewSpotSheet({
  engine,
  userPos,
  getMapCenter,
  picking,
  onPickStart,
  onPickEnd,
  onClose,
}: NewSpotSheetProps) {
  const friends = useFriends();
  const [name, setName] = useState("");
  const [emoji, setEmoji] = useState(EMOJIS[0]);
  const [source, setSource] = useState<"me" | "map">("me");
  const [picked, setPicked] = useState<LngLat | null>(null);
  // Der Spot-Record kennt keine Teilnehmer (Sichtbarkeit kommt mit CloudKit) —
  // die Auswahl ist deshalb bewusst reiner Bedienzustand.
  const [shared, setShared] = useState<ReadonlySet<string>>(() => new Set<string>());
  useEffect(() => {
    setShared(new Set(friends.map((f) => f.id)));
  }, [friends]);

  const point = source === "map" ? picked : userPos;
  const status = useZoneStatus(engine, point);

  const confirmPick = () => {
    hapticTap();
    const center = getMapCenter();
    if (center) setPicked(center);
    onPickEnd();
  };

  const cancelPick = () => {
    hapticTap();
    if (!picked) setSource("me");
    onPickEnd();
  };

  if (picking) {
    return (
      <>
        <div className="sp-cross" aria-hidden="true">
          <svg viewBox="0 0 54 54">
            <circle cx="27" cy="27" r="13" />
            <path d="M27 2v10M27 42v10M2 27h10M42 27h10" />
            <circle cx="27" cy="27" r="2" fill="currentColor" stroke="none" />
          </svg>
        </div>
        <div className="sp-pickbar glass">
          <div className="sp-pickbar-txt">
            <b>Position wählen</b>
            <span>Karte bewegen — der Punkt in der Mitte wird dein Spot.</span>
          </div>
          <button type="button" className="sp-cta blue" onClick={confirmPick}>
            Position bestätigen
          </button>
          <button type="button" className="sp-ghost" onClick={cancelPick}>
            Abbrechen
          </button>
        </div>
      </>
    );
  }

  const save = () => {
    if (!point || !name.trim()) return;
    hapticTap();
    void spotStore.addSpot({ name: name.trim(), emoji, lng: point.lng, lat: point.lat });
    onClose();
  };

  return (
    <Sheet onClose={onClose}>
      <h2 className="sp-h2">Spot markieren</h2>
      <div className="sp-hsub">
        Ein fester Ort für dich und deine Freunde — bleibt auf der Karte.
      </div>

      <div className="sp-sec">Name</div>
      <div className="sp-field">
        <span className="sp-field-emoji">{emoji}</span>
        <input
          type="text"
          value={name}
          placeholder="Unsere Bank"
          aria-label="Name des Spots"
          onChange={(e) => setName(e.target.value)}
          autoCorrect="off"
          autoComplete="off"
          enterKeyHint="done"
        />
      </div>
      <div className="sp-emojis">
        {EMOJIS.map((e) => (
          <button
            key={e}
            type="button"
            className={e === emoji ? "sp-emoji on" : "sp-emoji"}
            aria-label={`Symbol ${e}`}
            aria-pressed={e === emoji}
            onClick={() => {
              hapticTap();
              setEmoji(e);
            }}
          >
            {e}
          </button>
        ))}
      </div>

      <div className="sp-sec">Position</div>
      <div className="sp-seg">
        <button
          type="button"
          className={source === "me" ? "on" : undefined}
          onClick={() => {
            hapticTap();
            setSource("me");
          }}
        >
          Mein Standort
        </button>
        <button
          type="button"
          className={source === "map" ? "on" : undefined}
          onClick={() => {
            hapticTap();
            setSource("map");
            onPickStart();
          }}
        >
          Auf Karte wählen
        </button>
      </div>

      <PointNote point={point} status={status} />

      {friends.length > 0 && (
        <>
          <div className="sp-sec">Teilen mit</div>
          <div className="sp-chips">
            {friends.map((f) => (
              <FriendChip
                key={f.id}
                friend={f}
                on={shared.has(f.id)}
                onToggle={() =>
                  setShared((prev) => {
                    const next = new Set(prev);
                    if (!next.delete(f.id)) next.add(f.id);
                    return next;
                  })
                }
              />
            ))}
          </div>
          <div className="sp-note">
            <IconInfo />
            Nur geteilte Freunde sehen diesen Spot. Liegt im gemeinsamen iCloud-Bereich — nicht bei
            uns.
          </div>
        </>
      )}

      <div className="sp-actions">
        <button type="button" className="sp-cta" disabled={!name.trim() || !point} onClick={save}>
          Spot speichern
        </button>
        <button type="button" className="sp-ghost" onClick={onClose}>
          Abbrechen
        </button>
      </div>
    </Sheet>
  );
}

/** Status am gewählten Punkt — echte Werte aus der Zonen-Engine. */
function PointNote({ point, status }: { point: LngLat | null; status: ZoneStatus | null }) {
  if (!point) {
    return (
      <div className="sp-note">
        <IconInfo />
        Kein Standort — wähle den Punkt auf der Karte.
      </div>
    );
  }
  if (!status) {
    return (
      <div className="sp-note">
        <IconInfo />
        Status wird geprüft …
      </div>
    );
  }
  const kind = statusKind(status);
  if (kind !== "ok") {
    return (
      <div className="sp-note sp-note-no">
        <IconCross />
        {kind === "ban"
          ? "Hier verboten · Verbotszone — Status wird am Spot gespeichert."
          : "Jetzt verboten · Fußgängerzone bis 20 Uhr — Status wird am Spot gespeichert."}
      </div>
    );
  }
  const near = Number.isFinite(status.ban.nearestM)
    ? `nächste Verbotszone ${formatDistanceM(status.ban.nearestM)}`
    : "keine Verbotszone im Umkreis von 2 km";
  return (
    <div className="sp-note sp-note-ok">
      <IconCheck />
      {`Hier erlaubt · ${near} — Status wird am Spot gespeichert.`}
    </div>
  );
}

function FriendChip({
  friend,
  on,
  onToggle,
}: {
  friend: Friend;
  on: boolean;
  onToggle: () => void;
}) {
  return (
    <button
      type="button"
      className={on ? "sp-chip on" : "sp-chip"}
      aria-pressed={on}
      onClick={() => {
        hapticTap();
        onToggle();
      }}
    >
      <Avatar name={friend.name} color={friend.color} />
      {friend.name}
      {on && (
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <path d="M4.5 12.5l5 5 10-11" />
        </svg>
      )}
    </button>
  );
}

// --------------------------------------------------------------- Spot-Detail

interface SpotDetailSheetProps {
  spot: Spot;
  engine: ZoneEngine;
  userPos: LngLat | null;
  onInvite: () => void;
  onClose: () => void;
}

export function SpotDetailSheet({ spot, engine, userPos, onInvite, onClose }: SpotDetailSheetProps) {
  const inv = useActiveInvitation(spot.id);
  const friends = useFriends();
  const status = useZoneStatus(engine, spot);
  const [mode, setMode] = useState<"view" | "host-time" | "my-time">("view");
  const [draft, setDraft] = useState(() => Date.now());
  const [now] = useState(() => Date.now());

  const isHost = inv !== null && inv.hostId === SELF_ID;
  const own = inv?.replies.find((r) => r.participantId === SELF_ID) ?? null;
  const hostName =
    inv && !isHost ? (friends.find((f) => f.id === inv.hostId)?.name ?? "Gastgeber") : "";
  // Liegt der Anker schon in der Vergangenheit (Einladung läuft aus), muss das
  // Band bis zu ihm zurückreichen — sonst wäre die eigene Zeit nicht darstellbar.
  const tapeBase = inv ? Math.min(inv.time, now) : now;

  if (inv && mode === "host-time") {
    return (
      <Sheet onClose={onClose}>
        <h2 className="sp-h2">Zeit ändern</h2>
        <div className="sp-hsub">Alle Eingeladenen sehen die neue Zeit.</div>
        <SpotTape
          status={status}
          value={draft}
          onChange={setDraft}
          refTime={inv.time}
          refLabel="bisher"
          minTime={tapeBase}
        />
        <div className="sp-note">
          <IconBell />
          Zusagen bleiben bestehen — wer nicht mehr kann, meldet sich neu.
        </div>
        <button
          type="button"
          className="sp-cta blue"
          onClick={() => {
            hapticTap();
            void inviteStore.changeTime(inv.id, draft);
            setMode("view");
          }}
        >
          {draft === inv.time ? "Neue Zeit senden" : `Neue Zeit senden — ${fmtClock(draft)}`}
        </button>
        <button type="button" className="sp-ghost" onClick={() => setMode("view")}>
          Zurück
        </button>
      </Sheet>
    );
  }

  if (inv && mode === "my-time") {
    return (
      <Sheet onClose={onClose}>
        <h2 className="sp-h2">Wann bist du da?</h2>
        <div className="sp-hsub">
          {`${hostName} ist ab ${fmtClock(inv.time)} da — sag der Runde einfach deine Zeit.`}
        </div>
        <SpotTape
          status={status}
          value={draft}
          onChange={setDraft}
          refTime={inv.time}
          refLabel={`${hostName} ab`}
          minTime={tapeBase}
        />
        <div className="sp-note sp-note-ok">
          <IconCheck />
          Gilt als Zusage — für niemanden sonst ändert sich etwas.
        </div>
        <button
          type="button"
          className="sp-cta blue"
          onClick={() => {
            hapticTap();
            void inviteStore.setReply(inv.id, {
              participantId: SELF_ID,
              status: "in",
              arrivalTime: draft,
            });
            setMode("view");
          }}
        >
          {`Komme um ${fmtClock(draft)}`}
        </button>
        <button type="button" className="sp-ghost" onClick={() => setMode("view")}>
          Zurück
        </button>
      </Sheet>
    );
  }

  const rows = inv ? rsvpEntries(inv, friends) : [];

  return (
    <Sheet onClose={onClose}>
      <h2 className="sp-h2">{spot.name}</h2>
      {inv && (
        <div className="sp-hsub">
          {isHost
            ? `Deine Einladung — ${dayWord(inv.time, now).toLowerCase()} ${fmtClock(inv.time)}.`
            : `${hostName} lädt dich ein — ${dayWord(inv.time, now).toLowerCase()} ${fmtClock(inv.time)}.`}
        </div>
      )}
      <SpotCard spot={spot} status={status} userPos={userPos} />

      {inv && isHost && (
        <>
          <div className="sp-sec">Deine Zeit</div>
          <button
            type="button"
            className="sp-timerow"
            onClick={() => {
              hapticTap();
              setDraft(inv.time);
              setMode("host-time");
            }}
          >
            <svg className="sp-clock" viewBox="0 0 24 24" aria-hidden="true">
              <circle cx="12" cy="12" r="8.5" />
              <path d="M12 7.5V12l3 2" />
            </svg>
            <b>{`${dayWord(inv.time, now)} · ${fmtClock(inv.time)}`}</b>
            <span className="sp-edit">
              <svg viewBox="0 0 24 24" aria-hidden="true">
                <path d="M4 20h4L19.5 8.5a2.1 2.1 0 0 0-3-3L5 17z" />
              </svg>
              Ändern
            </span>
          </button>
        </>
      )}

      {inv && rows.length > 0 && (
        <>
          <div className="sp-sec">Wer kommt</div>
          {rows.map((r) => (
            <RsvpRow key={r.key} name={r.name} color={r.color} text={r.text} tone={r.tone} />
          ))}
        </>
      )}

      {inv && !isHost && !own && (
        <div className="sp-actions">
          <button
            type="button"
            className="sp-cta green"
            onClick={() => {
              hapticTap();
              void inviteStore.setReply(inv.id, { participantId: SELF_ID, status: "in" });
            }}
          >
            Bin dabei
          </button>
          <button
            type="button"
            className="sp-cta outline"
            onClick={() => {
              hapticTap();
              setDraft(inv.time);
              setMode("my-time");
            }}
          >
            Ich komme um …
          </button>
          <button
            type="button"
            className="sp-ghost"
            onClick={() => {
              hapticTap();
              void inviteStore.setReply(inv.id, { participantId: SELF_ID, status: "out" });
            }}
          >
            Kann nicht
          </button>
        </div>
      )}

      {!inv && friends.length > 0 && (
        <div className="sp-actions">
          <button
            type="button"
            className="sp-cta blue"
            onClick={() => {
              hapticTap();
              onInvite();
            }}
          >
            Einladen
          </button>
        </div>
      )}

      <div className="sp-actions">
        {inv && isHost && (
          <button
            type="button"
            className="sp-ghost danger"
            onClick={() => {
              hapticTap();
              void inviteStore.cancel(inv.id);
            }}
          >
            Einladung absagen
          </button>
        )}
        <button
          type="button"
          className="sp-ghost danger"
          onClick={() => {
            hapticTap();
            void spotStore.removeSpot(spot.id);
            onClose();
          }}
        >
          Spot entfernen
        </button>
        <button type="button" className="sp-ghost" onClick={onClose}>
          Schließen
        </button>
      </div>
    </Sheet>
  );
}

// ------------------------------------------------------------------ Einladen

interface InviteSheetProps {
  spot: Spot;
  engine: ZoneEngine;
  userPos: LngLat | null;
  /** Bestätigung nach dem Senden — die App zeigt sie als Toast. */
  onSent: (message: string) => void;
  onClose: () => void;
}

export function InviteSheet({ spot, engine, userPos, onSent, onClose }: InviteSheetProps) {
  const friends = useFriends();
  const status = useZoneStatus(engine, spot);
  // Bandanfang einmal einfrieren — sonst wandert „Jetzt" unter dem Finger.
  const [now] = useState(() => Date.now());
  const [time, setTime] = useState(now);
  const [picked, setPicked] = useState<ReadonlySet<string>>(() => new Set<string>());
  useEffect(() => {
    setPicked(new Set(friends.map((f) => f.id)));
  }, [friends]);

  const isNow = time - now < NOW_ZONE_MIN * MIN_MS;
  const names = friends.filter((f) => picked.has(f.id)).map((f) => f.name);

  const send = () => {
    hapticTap();
    // Die Einladung trägt nur den Anker; die Empfänger stehen bis zum
    // CloudKit-Transport in der Spot-Teilnehmerschaft, nicht im Record.
    void inviteStore.invite(spot.id, isNow ? Date.now() : time);
    onSent(`Einladung ${isNow ? "jetzt" : `für ${fmtClock(time)}`} · ${names.join(", ")} sehen sie`);
    onClose();
  };

  return (
    <Sheet onClose={onClose}>
      <h2 className="sp-h2">Einladen</h2>
      <div className="sp-hsub">Verabrede dich an eurem Spot — egal, wo du gerade bist.</div>
      <SpotCard spot={spot} status={status} userPos={userPos} />

      <div className="sp-sec">Wann</div>
      <SpotTape status={status} value={time} onChange={setTime} minTime={now} />

      <div className="sp-sec">Wer</div>
      <div className="sp-chips">
        {friends.map((f) => (
          <FriendChip
            key={f.id}
            friend={f}
            on={picked.has(f.id)}
            onToggle={() =>
              setPicked((prev) => {
                const next = new Set(prev);
                if (!next.delete(f.id)) next.add(f.id);
                return next;
              })
            }
          />
        ))}
      </div>

      <div className="sp-note">
        <IconPin />
        Geteilt wird der Spot — nie dein Live-Standort.
      </div>

      <button type="button" className="sp-cta blue" disabled={picked.size === 0} onClick={send}>
        {isNow ? "Jetzt einladen" : `Für ${fmtClock(time)} einladen`}
      </button>
      <button type="button" className="sp-ghost" onClick={onClose}>
        Abbrechen
      </button>
    </Sheet>
  );
}

// -------------------------------------------------------------------- Icons

function IconCheck() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M4.5 12.5l5 5 10-11" />
    </svg>
  );
}

function IconCross() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M6 6l12 12M18 6L6 18" />
    </svg>
  );
}

function IconInfo() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 8v5M12 16.2v.3" />
    </svg>
  );
}

function IconPin() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M12 21s-6.5-5.3-6.5-10a6.5 6.5 0 0 1 13 0c0 4.7-6.5 10-6.5 10z" />
      <circle cx="12" cy="10.5" r="2.4" />
    </svg>
  );
}

function IconBell() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M6 9a6 6 0 0 1 12 0c0 5 2 6 2 6H4s2-1 2-6" />
      <path d="M10 20a2.2 2.2 0 0 0 4 0" />
    </svg>
  );
}
