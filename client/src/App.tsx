import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import type { Map as MapLibreMap } from "maplibre-gl";
import MapView from "./components/MapView";
import StatusBar from "./components/StatusBar";
import SearchBar from "./components/SearchBar";
import Onboarding from "./components/Onboarding";
import InfoSheet from "./components/InfoSheet";
import {
  FriendsSheet,
  InviteSheet,
  NewSpotSheet,
  ProfilePromptSheet,
  SpotDetailSheet,
} from "./components/SpotSheets";
import { Geolocation } from "@capacitor/geolocation";
import { useLocation } from "./lib/location";
import { ZoneEngine, type ZoneStatus } from "./lib/zones";
import { pedestrianBanActive } from "./lib/time";
import { distanceM, type LngLat } from "./lib/geo";
import { hapticTap, initNative } from "./lib/native";
import { SearchController, WorkerOfflineIndex, type Result } from "./lib/search";
import {
  inviteStore,
  invitationActive,
  spotSync,
  useSpots,
  useSyncState,
  type Invitation,
} from "./lib/spots";
import "./App.css";

const FALLBACK_CENTER: LngLat = { lng: 9.7386, lat: 52.3728 };
const TILES_URL = "zones.pmtiles";

function loadLastPos(): LngLat | null {
  try {
    const raw = localStorage.getItem("gz_last_pos");
    return raw ? (JSON.parse(raw) as LngLat) : null;
  } catch {
    return null;
  }
}

/** Ziel-Modus: der gewählte Ort und sein Zonen-Status. */
interface Target {
  result: Result;
  status: ZoneStatus | null;
}

/** Genau EIN offenes Sheet — parallele Booleans könnten sich widersprechen. */
type SheetState =
  | { kind: "newspot" }
  /** „Auf Karte wählen": Sheet eingeklappt, Karte gehört dem Nutzer. */
  | { kind: "pick" }
  | { kind: "detail"; spotId: string }
  | { kind: "invite"; spotId: string }
  | { kind: "friends"; autoInvite?: boolean };

export default function App() {
  const [onboarded, setOnboarded] = useState(() => localStorage.getItem("gz_onboarded") === "1");
  const [status, setStatus] = useState<ZoneStatus | null>(null);
  const [timeActive, setTimeActive] = useState(pedestrianBanActive());
  const [now, setNow] = useState(() => Date.now());
  const [infoOpen, setInfoOpen] = useState(false);
  const [target, setTarget] = useState<Target | null>(null);
  const [sheet, setSheet] = useState<SheetState | null>(null);
  const sync = useSyncState();
  const [toast, setToast] = useState<{ text: string; on: boolean }>({ text: "", on: false });

  const location = useLocation(onboarded);
  const engine = useMemo(() => new ZoneEngine(new URL(TILES_URL, window.location.href).href), []);
  const lastEval = useRef<LngLat | null>(null);
  const mapRef = useRef<MapLibreMap | null>(null);

  // Der Index lebt im Worker; die Instanz muss den StrictMode-Doppelrender
  // überleben, sonst laufen zwei Worker.
  const searchRef = useRef<SearchController | null>(null);
  if (!searchRef.current) {
    searchRef.current = new SearchController({ offline: new WorkerOfflineIndex() });
  }
  const search = searchRef.current;

  useEffect(() => {
    void initNative();
  }, []);

  // Der CloudKit-Sync lebt so lange wie die App. Kein Teardown im Effekt: der
  // StrictMode-Doppelmount würde sonst die Listener der überlebenden Instanz
  // abräumen. Ein zweiter start() ist ein No-Op.
  useEffect(() => {
    void spotSync.start();
  }, []);

  // Permission schon erteilt (z. B. Reinstall) → Onboarding ist redundant
  useEffect(() => {
    if (onboarded) return;
    Geolocation.checkPermissions()
      .then((p) => {
        if (p.location === "granted") {
          localStorage.setItem("gz_onboarded", "1");
          setOnboarded(true);
        }
      })
      .catch(() => {});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Zeitfenster-Flip (7/20 Uhr) ohne App-Neustart. Derselbe Takt trägt `now`:
  // setTimeActive mit unverändertem Boolean lässt React aussteigen — abgelaufene
  // Einladungen blieben sonst bis zum nächsten Flip auf der Karte stehen.
  useEffect(() => {
    const t = setInterval(() => {
      setTimeActive(pedestrianBanActive());
      setNow(Date.now());
    }, 30_000);
    return () => clearInterval(t);
  }, []);

  const pos = location.kind === "ready" ? location.pos : null;

  // Status neu berechnen, wenn >15 m bewegt
  useEffect(() => {
    if (!pos) return;
    if (lastEval.current && distanceM(lastEval.current, pos) < 15 && status) return;
    lastEval.current = pos;
    let stale = false;
    engine
      .status(pos)
      .then((s) => {
        if (!stale) setStatus(s);
      })
      .catch(() => {});
    localStorage.setItem("gz_last_pos", JSON.stringify(pos));
    return () => {
      stale = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pos?.lng, pos?.lat, timeActive, engine]);

  // Das Offline-Ranking der Suche kennt die Nutzerposition.
  useEffect(() => {
    search.setUserPos(pos);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pos?.lng, pos?.lat, search]);

  // Ziel-Status: dieselbe Engine, nur an einem anderen Punkt. Beim
  // Zeitfenster-Flip neu bewerten wie beim GPS-Status.
  const targetResult = target?.result ?? null;
  useEffect(() => {
    if (!targetResult) return;
    let stale = false;
    engine
      .status({ lng: targetResult.lng, lat: targetResult.lat })
      .then((s) => {
        if (!stale) {
          setTarget((t) => (t && t.result === targetResult ? { result: t.result, status: s } : t));
        }
      })
      .catch(() => {});
    return () => {
      stale = true;
    };
  }, [targetResult, timeActive, engine]);

  // ---------------------------------------------------------------- Community
  const spots = useSpots();
  const invitations = useSyncExternalStore(
    useCallback((cb: () => void) => inviteStore.subscribe(cb), []),
    () => inviteStore.getInvitations(),
    () => inviteStore.getInvitations(),
  );

  /** Anker-Zeit je Spot mit laufender Einladung — bei mehreren die jüngste. */
  const sessions = useMemo(() => {
    const latest = new Map<string, Invitation>();
    for (const inv of invitations) {
      if (!invitationActive(inv, now)) continue;
      const cur = latest.get(inv.spotId);
      if (!cur || inv.createdAt >= cur.createdAt) latest.set(inv.spotId, inv);
    }
    const out = new Map<string, number>();
    for (const [spotId, inv] of latest) out.set(spotId, inv.time);
    return out;
  }, [invitations, now]);

  const sheetSpot =
    sheet && (sheet.kind === "detail" || sheet.kind === "invite")
      ? (spots.find((s) => s.id === sheet.spotId) ?? null)
      : null;

  const onSpotTap = useCallback((spotId: string) => setSheet({ kind: "detail", spotId }), []);
  const onMapInstance = useCallback((map: MapLibreMap) => {
    mapRef.current = map;
  }, []);
  const getMapCenter = useCallback((): LngLat | null => {
    const map = mapRef.current;
    if (!map) return null;
    const c = map.getCenter();
    return { lng: c.lng, lat: c.lat };
  }, []);

  const showToast = useCallback((text: string) => setToast({ text, on: true }), []);
  useEffect(() => {
    if (!toast.on) return;
    const t = setTimeout(() => setToast((s) => ({ ...s, on: false })), 2600);
    return () => clearTimeout(t);
  }, [toast]);

  /** Ziel-Modus beenden: Pin weg, Feld leer, zurück auf den eigenen Standort. */
  const clearTarget = () => {
    // Ohne Ziel ist das nur ein geleertes Suchfeld — dann die Karte in Ruhe lassen.
    if (target) window.dispatchEvent(new Event("gz:recenter"));
    setTarget(null);
  };

  const center = pos ?? loadLastPos() ?? FALLBACK_CENTER;

  return (
    <>
      <MapView
        tilesUrl={TILES_URL}
        center={center}
        userPos={pos}
        accuracyM={location.kind === "ready" ? location.accuracyM : 50}
        timeActive={timeActive}
        target={targetResult ? { lng: targetResult.lng, lat: targetResult.lat } : null}
        spots={spots}
        sessions={sessions}
        onSpotTap={onSpotTap}
        pickCenter={sheet?.kind === "pick"}
        onMapInstance={onMapInstance}
        onMapReady={() => search.prewarm()}
      />

      <SearchBar
        controller={search}
        selected={targetResult}
        userPos={pos}
        onSelect={(r) => setTarget({ result: r, status: null })}
        onClear={clearTarget}
      />
      <StatusBar
        status={target ? target.status : status}
        locating={location.kind === "locating" || location.kind === "idle"}
        denied={location.kind === "denied"}
        target={targetResult}
        onClearTarget={clearTarget}
      />

      {sheet?.kind !== "pick" && (
      <div className="fabs">
        <button
          className="fab glass sp-add"
          aria-label="Spot markieren"
          onClick={() => {
            hapticTap();
            setSheet({ kind: "newspot" });
          }}
        >
          <svg viewBox="0 0 24 24">
            <path d="M12 21s-6.5-5.3-6.5-10a6.5 6.5 0 0 1 13 0c0 4.7-6.5 10-6.5 10z" />
            <path d="M12 8v6M9 11h6" />
          </svg>
        </button>
        <button
          className="fab glass"
          aria-label="Freunde"
          onClick={() => {
            hapticTap();
            setSheet({ kind: "friends" });
          }}
        >
          <svg viewBox="0 0 24 24">
            <circle cx="9.5" cy="8.5" r="3.4" />
            <path d="M3.5 19.5c0-3.1 2.7-5 6-5s6 1.9 6 5" />
            <path d="M16 5.6a3.4 3.4 0 0 1 0 6.6M17.5 14.9c2 .6 3.4 2.2 3.4 4.6" />
          </svg>
        </button>
        <button
          className="fab glass"
          aria-label="Auf meinen Standort zentrieren"
          onClick={() => {
            hapticTap();
            window.dispatchEvent(new Event("gz:recenter"));
          }}
        >
          <svg viewBox="0 0 24 24">
            <path d="M12 3v2M12 19v2M3 12h2M19 12h2" />
            <circle cx="12" cy="12" r="6" />
            <circle cx="12" cy="12" r="1.6" fill="currentColor" stroke="none" />
          </svg>
        </button>
        <button
          className="fab glass"
          aria-label="Info und Datenquellen"
          onClick={() => {
            hapticTap();
            setInfoOpen(true);
          }}
        >
          <svg viewBox="0 0 24 24">
            <circle cx="12" cy="12" r="8.5" />
            <path d="M12 11v5" />
            <circle cx="12" cy="7.6" r="0.4" fill="currentColor" />
          </svg>
        </button>
      </div>
      )}

      {(sheet?.kind === "newspot" || sheet?.kind === "pick") && (
        <NewSpotSheet
          engine={engine}
          userPos={pos}
          getMapCenter={getMapCenter}
          picking={sheet.kind === "pick"}
          onPickStart={() => setSheet({ kind: "pick" })}
          onPickEnd={() => setSheet({ kind: "newspot" })}
          onClose={() => setSheet(null)}
        />
      )}

      {sheet?.kind === "detail" && sheetSpot && (
        <SpotDetailSheet
          spot={sheetSpot}
          engine={engine}
          userPos={pos}
          onInvite={() => setSheet({ kind: "invite", spotId: sheetSpot.id })}
          onAddFriend={() => setSheet({ kind: "friends", autoInvite: true })}
          onNotice={showToast}
          onClose={() => setSheet(null)}
        />
      )}

      {sheet?.kind === "invite" && sheetSpot && (
        <InviteSheet
          spot={sheetSpot}
          engine={engine}
          userPos={pos}
          onNotice={showToast}
          onClose={() => setSheet(null)}
        />
      )}

      {sheet?.kind === "friends" && (
        <FriendsSheet
          autoInvite={sheet.autoInvite}
          onNotice={showToast}
          onClose={() => setSheet(null)}
        />
      )}

      {/* Nach einem Beitritt über einen Link: Profil nachtragen. Tritt zurück,
          solange ein anderes Sheet offen ist — sonst überdeckt er eine
          Handlung, die der Nutzer gerade selbst begonnen hat. */}
      {sheet === null && sync.profilePrompt && (
        <ProfilePromptSheet onNotice={showToast} onClose={() => void spotSync.skipProfilePrompt()} />
      )}

      <div
        className={`sp-toast${sheet ? " top" : ""}${toast.on ? " show" : ""}`}
        role="status"
      >
        {toast.text}
      </div>

      {location.kind === "denied" && (
        <div className="loc-hint glass">
          Standort nicht freigegeben — Status zeigt nichts an. In den iOS-Einstellungen aktivieren.
        </div>
      )}

      <InfoSheet open={infoOpen} onClose={() => setInfoOpen(false)} />

      {!onboarded && (
        <Onboarding
          onDone={() => {
            localStorage.setItem("gz_onboarded", "1");
            setOnboarded(true);
          }}
        />
      )}
    </>
  );
}
