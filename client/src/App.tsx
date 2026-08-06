import { useEffect, useMemo, useRef, useState } from "react";
import MapView from "./components/MapView";
import StatusPill from "./components/StatusPill";
import BottomSheet from "./components/BottomSheet";
import ZoneList from "./components/ZoneList";
import SearchBar from "./components/SearchBar";
import Onboarding from "./components/Onboarding";
import InfoSheet from "./components/InfoSheet";
import { Geolocation } from "@capacitor/geolocation";
import { useLocation } from "./lib/location";
import { ZoneEngine, type ZoneStatus } from "./lib/zones";
import { pedestrianBanActive } from "./lib/time";
import { distanceM, type LngLat } from "./lib/geo";
import { hapticTap, initNative } from "./lib/native";
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

export default function App() {
  const [onboarded, setOnboarded] = useState(() => localStorage.getItem("gz_onboarded") === "1");
  const [status, setStatus] = useState<ZoneStatus | null>(null);
  const [timeActive, setTimeActive] = useState(pedestrianBanActive());
  const [infoOpen, setInfoOpen] = useState(false);

  const location = useLocation(onboarded);
  const engine = useMemo(() => new ZoneEngine(new URL(TILES_URL, window.location.href).href), []);
  const lastEval = useRef<LngLat | null>(null);

  useEffect(() => {
    void initNative();
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

  // Zeitfenster-Flip (7/20 Uhr) ohne App-Neustart
  useEffect(() => {
    const t = setInterval(() => setTimeActive(pedestrianBanActive()), 30_000);
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

  const center = pos ?? loadLastPos() ?? FALLBACK_CENTER;

  return (
    <>
      <MapView
        tilesUrl={TILES_URL}
        center={center}
        userPos={pos}
        accuracyM={location.kind === "ready" ? location.accuracyM : 50}
        timeActive={timeActive}
      />

      <SearchBar />
      <StatusPill status={status} locating={location.kind === "locating" || location.kind === "idle"} />

      <div className="fabs">
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

      {location.kind === "denied" && (
        <div className="loc-hint glass">
          Standort nicht freigegeben — Status zeigt nichts an. In den iOS-Einstellungen aktivieren.
        </div>
      )}

      <BottomSheet peekHeight={214} expandedHeight={420}>
        <h2 className="sheet-title">In deiner Nähe</h2>
        <div className="sheet-scroll">
          <ZoneList status={status} />
          <p className="sheet-foot">
            Umkreis 2 km · Daten © OpenStreetMap · keine Rechtsberatung
          </p>
        </div>
      </BottomSheet>

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
