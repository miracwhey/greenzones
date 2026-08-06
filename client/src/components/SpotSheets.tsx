/**
 * Sheets des Community-Features — Port der abgenommenen Mockups
 * mockup/community.html (Spot markieren · Freunde) und mockup/invite.html
 * (Einladen · Antworten · Verwalten).
 *
 * Konzept v2.2: die Host-Zeit ist ein ANKER, jede Antwort trägt ihren eigenen
 * Zustand. Es gibt keinen Verhandlungs- oder Entscheidungs-Flow — niemandes
 * Zeit stellt sich durch die Antwort eines anderen um.
 *
 * Darstellung kommt über Props (Spot, Engine, Position), der Bestand über die
 * Store-Hooks. Jede Änderung an geteilten Daten läuft über `spotSync`, nie am
 * Store vorbei: dort liegt die Reihenfolge Cloud-zuerst und damit die Garantie,
 * dass nichts lokal als „gesendet" dasteht, was nie rausging.
 *
 * Die Sheets liegen im Rahmen aus App.css (.detail-backdrop/.detail/.grab),
 * alles Eigene ist sp-präfixiert.
 */
import { useEffect, useState, type ReactNode } from "react";
import { Share } from "@capacitor/share";
import TimeTape from "./TimeTape";
import { statusKind } from "./StatusBar";
import { distanceM, formatDistanceM, type LngLat } from "../lib/geo";
import type { ZoneEngine, ZoneStatus } from "../lib/zones";
import { hapticTap } from "../lib/native";
import { cloudMessage } from "../lib/cloudkit";
import {
  SELF_ID,
  friendLabel,
  spotSync,
  useActiveInvitation,
  useFriends,
  useSpots,
  useSyncState,
  type Friend,
  type Invitation,
  type Reply,
  type Spot,
} from "../lib/spots";
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

/**
 * Cloud-Aktion mit ehrlichem Ausgang: klappt der Write nicht, sagt es die App
 * und der lokale Bestand bleibt, wie er war (der Sync schreibt Cloud-zuerst).
 */
function cloudAction(onNotice: (text: string) => void) {
  return (action: () => Promise<unknown>): void => {
    hapticTap();
    action().catch((error: unknown) => onNotice(cloudMessage(error)));
  };
}

/**
 * Ruhiger Hinweis auf den Kontostatus — Wortlaut aus dem Contract. Kein
 * Modal, kein Dauerbanner: die App bleibt ohne iCloud voll lokal nutzbar.
 */
function CloudHint() {
  const sync = useSyncState();
  if (sync.status === "available" || sync.status === "unknown") return null;
  return (
    <div className="sp-note">
      <IconInfo />
      {sync.status === "noAccount"
        ? "Für Freunde & geteilte Spots bei iCloud anmelden — Einstellungen → [dein Name]."
        : "iCloud antwortet gerade nicht — deine Spots bleiben lokal da."}
    </div>
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
 * „Wer kommt": Gastgeber (falls fremd) · die echten Spot-Teilnehmer · eigene
 * Antwort. Teilnehmer ohne Antwort stehen auf „offen" — das ist ein Zustand,
 * kein Fehlen. Wer nur als Antwort auftaucht (Freundesliste noch nicht
 * synchronisiert), steht namenlos, aber sichtbar dabei.
 */
function rsvpEntries(inv: Invitation, friends: Friend[], participantIds: string[]): RsvpEntry[] {
  const rows: RsvpEntry[] = [];
  const known = (id: string): Friend | undefined => friends.find((f) => f.id === id);
  const row = (id: string, reply: Reply | undefined): RsvpEntry => {
    const friend = known(id);
    return {
      key: id,
      name: friend ? friendLabel(friend) : "Freund",
      color: friend?.color ?? "var(--ink-3)",
      ...replyState(reply, false),
    };
  };

  const seen = new Set<string>([SELF_ID]);
  if (inv.hostId !== SELF_ID) {
    const host = known(inv.hostId);
    seen.add(inv.hostId);
    rows.push({
      key: `host-${inv.hostId}`,
      name: host ? friendLabel(host) : "Gastgeber",
      color: host?.color ?? "var(--accent)",
      text: `ab ${fmtClock(inv.time)} · Gastgeber`,
      tone: "in",
    });
  }
  for (const id of participantIds) {
    if (seen.has(id)) continue;
    seen.add(id);
    rows.push(row(id, inv.replies.find((r) => r.participantId === id)));
  }
  const own = inv.replies.find((r) => r.participantId === SELF_ID);
  if (own) rows.push({ key: "self", name: "Du", color: "var(--accent)", ...replyState(own, true) });
  for (const r of inv.replies) {
    if (seen.has(r.participantId)) continue;
    seen.add(r.participantId);
    rows.push(row(r.participantId, r));
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
  // Die Auswahl entscheidet, ob der Spot rein lokal bleibt (leer) oder in eine
  // geteilte Zone geht — sie ist der Auslöser für den CloudKit-Share.
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
    // Der Spot liegt sofort lokal; das Teilen holt der Sync notfalls nach
    // (Outbox) — deshalb blockiert das Speichern nicht auf dem Netz.
    void spotSync.createSpot({ name: name.trim(), emoji, lng: point.lng, lat: point.lat }, [
      ...shared,
    ]);
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

      <CloudHint />

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
      <Avatar name={friendLabel(friend)} color={friend.color} />
      {friendLabel(friend)}
      {on && (
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <path d="M4.5 12.5l5 5 10-11" />
        </svg>
      )}
    </button>
  );
}

/**
 * Teilnehmer eines geteilten Spots — Anzeige statt Auswahl: die Einladung hängt
 * am Spot, alle seine Teilnehmer sehen sie. Eine Auswahl hätte im Record kein
 * Gegenstück und würde etwas versprechen, das die Zone nicht einhält.
 */
function ParticipantChips({ ids, friends }: { ids: string[]; friends: Friend[] }) {
  return (
    <div className="sp-chips">
      {ids.map((id) => {
        const friend = friends.find((f) => f.id === id);
        const name = friend ? friendLabel(friend) : "Freund";
        return (
          <span key={id} className="sp-chip on">
            <Avatar name={name} color={friend?.color ?? "var(--ink-3)"} />
            {name}
          </span>
        );
      })}
    </div>
  );
}

// --------------------------------------------------------------- Spot-Detail

interface SpotDetailSheetProps {
  spot: Spot;
  engine: ZoneEngine;
  userPos: LngLat | null;
  onInvite: () => void;
  /** Meldung an den Nutzer (Toast) — trägt auch gescheiterte Cloud-Writes. */
  onNotice: (text: string) => void;
  onClose: () => void;
}

export function SpotDetailSheet({
  spot,
  engine,
  userPos,
  onInvite,
  onNotice,
  onClose,
}: SpotDetailSheetProps) {
  const inv = useActiveInvitation(spot.id);
  const friends = useFriends();
  const status = useZoneStatus(engine, spot);
  const [mode, setMode] = useState<"view" | "host-time" | "my-time" | "share">("view");
  const [draft, setDraft] = useState(() => Date.now());
  const [now] = useState(() => Date.now());
  const [addTo, setAddTo] = useState<ReadonlySet<string>>(() => new Set<string>());

  const run = cloudAction(onNotice);
  const participants = spot.participantIds ?? [];
  const isMine = spot.ownerId === undefined || spot.ownerId === SELF_ID;
  const isHost = inv !== null && inv.hostId === SELF_ID;
  const own = inv?.replies.find((r) => r.participantId === SELF_ID) ?? null;
  const host = inv && !isHost ? friends.find((f) => f.id === inv.hostId) : undefined;
  const hostName = inv && !isHost ? (host ? friendLabel(host) : "Gastgeber") : "";
  // Liegt der Anker schon in der Vergangenheit (Einladung läuft aus), muss das
  // Band bis zu ihm zurückreichen — sonst wäre die eigene Zeit nicht darstellbar.
  const tapeBase = inv ? Math.min(inv.time, now) : now;
  const shareable = friends.filter((f) => !participants.includes(f.id));

  if (mode === "share") {
    return (
      <Sheet onClose={onClose}>
        <h2 className="sp-h2">Spot teilen</h2>
        <div className="sp-hsub">Gewählte Freunde bekommen den Spot dauerhaft auf ihre Karte.</div>
        <div className="sp-chips">
          {shareable.map((f) => (
            <FriendChip
              key={f.id}
              friend={f}
              on={addTo.has(f.id)}
              onToggle={() =>
                setAddTo((prev) => {
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
          Der Spot liegt dann in eurem gemeinsamen iCloud-Bereich — nicht bei uns.
        </div>
        <button
          type="button"
          className="sp-cta blue"
          disabled={addTo.size === 0}
          onClick={() => {
            run(() => spotSync.shareSpot(spot.id, [...addTo]));
            setAddTo(new Set<string>());
            setMode("view");
          }}
        >
          Spot teilen
        </button>
        <button type="button" className="sp-ghost" onClick={() => setMode("view")}>
          Zurück
        </button>
      </Sheet>
    );
  }

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
            run(() => spotSync.changeInvitationTime(inv.id, draft));
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
            run(() => spotSync.reply(inv.id, "in", draft));
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

  const rows = inv ? rsvpEntries(inv, friends, participants) : [];

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

      {!inv && participants.length > 0 && (
        <>
          <div className="sp-sec">Geteilt mit</div>
          <ParticipantChips ids={participants} friends={friends} />
        </>
      )}

      {spot.sharePending && (
        <div className="sp-note">
          <IconInfo />
          Teilen wird nachgeholt, sobald du wieder Netz hast — lokal ist der Spot längst da.
        </div>
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
            onClick={() => run(() => spotSync.reply(inv.id, "in"))}
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
            onClick={() => run(() => spotSync.reply(inv.id, "out"))}
          >
            Kann nicht
          </button>
        </div>
      )}

      <div className="sp-actions">
        {!inv && spot.zoneName && (
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
        )}
        {isMine && shareable.length > 0 && (
          <button
            type="button"
            className={spot.zoneName ? "sp-cta outline" : "sp-cta blue"}
            onClick={() => {
              hapticTap();
              setAddTo(new Set(shareable.map((f) => f.id)));
              setMode("share");
            }}
          >
            {spot.zoneName ? "Weiteren Freunden geben" : "Mit Freunden teilen"}
          </button>
        )}
      </div>

      {!spot.zoneName && friends.length === 0 && <CloudHint />}

      <div className="sp-actions">
        {inv && isHost && (
          <button
            type="button"
            className="sp-ghost danger"
            onClick={() => run(() => spotSync.cancelInvitation(inv.id))}
          >
            Einladung absagen
          </button>
        )}
        <button
          type="button"
          className="sp-ghost danger"
          onClick={() => {
            run(() => spotSync.removeSpot(spot.id));
            onClose();
          }}
        >
          {isMine ? "Spot entfernen" : "Spot verlassen"}
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
  /** Bestätigung oder Fehlermeldung — die App zeigt sie als Toast. */
  onNotice: (message: string) => void;
  onClose: () => void;
}

export function InviteSheet({ spot, engine, userPos, onNotice, onClose }: InviteSheetProps) {
  const friends = useFriends();
  const status = useZoneStatus(engine, spot);
  // Bandanfang einmal einfrieren — sonst wandert „Jetzt" unter dem Finger.
  const [now] = useState(() => Date.now());
  const [time, setTime] = useState(now);
  const [sending, setSending] = useState(false);

  const isNow = time - now < NOW_ZONE_MIN * MIN_MS;
  const participants = spot.participantIds ?? [];
  const names = participants.map((id) => {
    const friend = friends.find((f) => f.id === id);
    return friend ? friendLabel(friend) : "Freund";
  });

  /**
   * Die Einladung geht erst raus, dann in den lokalen Bestand. Scheitert der
   * Cloud-Write, bleibt das Sheet offen und es gibt KEINE lokale Einladung —
   * ein flüchtiger Termin wird ehrlich abgebrochen, nie nachgeliefert.
   */
  const send = () => {
    hapticTap();
    setSending(true);
    spotSync
      .invite(spot.id, isNow ? Date.now() : time)
      .then(() => {
        onNotice(
          `Einladung ${isNow ? "jetzt" : `für ${fmtClock(time)}`}${
            names.length > 0 ? ` · ${names.join(", ")} sehen sie` : ""
          }`,
        );
        onClose();
      })
      .catch((error: unknown) => {
        setSending(false);
        onNotice(cloudMessage(error));
      });
  };

  return (
    <Sheet onClose={onClose}>
      <h2 className="sp-h2">Einladen</h2>
      <div className="sp-hsub">Verabrede dich an eurem Spot — egal, wo du gerade bist.</div>
      <SpotCard spot={spot} status={status} userPos={userPos} />

      <div className="sp-sec">Wann</div>
      <SpotTape status={status} value={time} onChange={setTime} minTime={now} />

      <div className="sp-sec">Wer</div>
      {participants.length > 0 ? (
        <ParticipantChips ids={participants} friends={friends} />
      ) : (
        <div className="sp-note">
          <IconInfo />
          Noch niemand hat den Spot angenommen — die Einladung wartet dort auf sie.
        </div>
      )}

      <div className="sp-note">
        <IconPin />
        Geteilt wird der Spot — nie dein Live-Standort.
      </div>

      <button type="button" className="sp-cta blue" disabled={sending} onClick={send}>
        {isNow ? "Jetzt einladen" : `Für ${fmtClock(time)} einladen`}
      </button>
      <button type="button" className="sp-ghost" onClick={onClose}>
        Abbrechen
      </button>
    </Sheet>
  );
}

// ------------------------------------------------------------------- Freunde

function sharedSpotsLine(names: string[]): string {
  if (names.length === 0) return "Noch keine gemeinsamen Spots";
  const word = names.length === 1 ? "gemeinsamer Spot" : "gemeinsame Spots";
  return `${names.length} ${word} · ${names.join(", ")}`;
}

interface FriendsSheetProps {
  /** Meldung an den Nutzer (Toast). */
  onNotice: (text: string) => void;
  onClose: () => void;
}

/**
 * Freundesliste nach mockup/community.html (Szenario „friends").
 *
 * Freunde entstehen ausschließlich über einen Einladungslink: kein
 * Verzeichnis, keine Kontakte, keine Handynummer. Der eigene Anzeigename wird
 * genau einmal erfragt und liegt lokal — er ist frei wählbar und für den Link
 * das Einzige, was der Empfänger von dir sieht.
 */
export function FriendsSheet({ onNotice, onClose }: FriendsSheetProps) {
  const friends = useFriends();
  const spots = useSpots();
  const sync = useSyncState();
  const [ask, setAsk] = useState<"invite" | "rename" | null>(null);
  const [name, setName] = useState(sync.displayName);
  const [busy, setBusy] = useState(false);

  const shared = spots.filter((s) => s.zoneName !== undefined || s.sharePending === true);
  const spotNames = (friendId: string): string[] =>
    shared.filter((s) => (s.participantIds ?? []).includes(friendId)).map((s) => s.name);

  const invite = async (displayName: string): Promise<void> => {
    setBusy(true);
    let url: string;
    try {
      url = await spotSync.inviteFriend(displayName);
    } catch (error) {
      setBusy(false);
      onNotice(cloudMessage(error));
      return;
    }
    setBusy(false);
    setAsk(null);
    try {
      await Share.share({
        title: "GreenZones",
        text: `${displayName} teilt seine Spots mit dir.`,
        url,
        dialogTitle: "Freund einladen",
      });
    } catch {
      // Abbruch im Share-Sheet ist keine Störung — der Link bleibt gültig.
    }
  };

  const rename = async (displayName: string): Promise<void> => {
    setBusy(true);
    try {
      await spotSync.setDisplayName(displayName);
      setAsk(null);
    } catch (error) {
      onNotice(cloudMessage(error));
    }
    setBusy(false);
  };

  if (ask !== null) {
    const forInvite = ask === "invite";
    return (
      <Sheet onClose={onClose}>
        <h2 className="sp-h2">Dein Name</h2>
        <div className="sp-hsub">
          So stehst du in der Freundesliste der anderen. Frei wählbar — kein Konto, kein Klarname.
        </div>
        <div className="sp-field">
          <span className="sp-field-emoji">🙂</span>
          <input
            type="text"
            value={name}
            placeholder="Leon"
            aria-label="Dein Anzeigename"
            onChange={(e) => setName(e.target.value)}
            autoCorrect="off"
            autoComplete="off"
            enterKeyHint="done"
          />
        </div>
        <button
          type="button"
          className="sp-cta blue"
          disabled={busy || !name.trim()}
          onClick={() => void (forInvite ? invite(name.trim()) : rename(name.trim()))}
        >
          {forInvite ? "Weiter — Link teilen" : "Name speichern"}
        </button>
        <button type="button" className="sp-ghost" onClick={() => setAsk(null)}>
          Zurück
        </button>
      </Sheet>
    );
  }

  return (
    <Sheet onClose={onClose}>
      <h2 className="sp-h2">Freunde</h2>
      <div className="sp-hsub">
        {friends.length === 0
          ? "Noch niemand — teilt einen Link, dann seht ihr eure Spots gemeinsam."
          : `${friends.length} ${friends.length === 1 ? "Freund" : "Freunde"} · ${shared.length} ${
              shared.length === 1 ? "gemeinsamer Spot" : "gemeinsame Spots"
            }`}
      </div>

      {friends.map((f) => (
        <div className="sp-member" key={f.id}>
          <Avatar name={friendLabel(f)} color={f.color} />
          <div className="sp-member-who">
            <b>{friendLabel(f)}</b>
            <span>{sharedSpotsLine(spotNames(f.id))}</span>
          </div>
        </div>
      ))}

      {sync.displayName !== "" && (
        <>
          <div className="sp-sec">Dein Name</div>
          <button
            type="button"
            className="sp-timerow"
            onClick={() => {
              hapticTap();
              setName(sync.displayName);
              setAsk("rename");
            }}
          >
            <b>{sync.displayName}</b>
            <span className="sp-edit">
              <svg viewBox="0 0 24 24" aria-hidden="true">
                <path d="M4 20h4L19.5 8.5a2.1 2.1 0 0 0-3-3L5 17z" />
              </svg>
              Ändern
            </span>
          </button>
        </>
      )}

      <button
        type="button"
        className="sp-invite-btn"
        disabled={busy}
        onClick={() => {
          hapticTap();
          if (sync.displayName === "") {
            setAsk("invite");
            return;
          }
          void invite(sync.displayName);
        }}
      >
        <IconShare />
        Freund hinzufügen — Link teilen
      </button>

      <CloudHint />

      <button type="button" className="sp-ghost" onClick={onClose}>
        Schließen
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

function IconShare() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M12 15V4M8 7.5 12 3.5l4 4" />
      <path d="M5 12v7h14v-7" />
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
