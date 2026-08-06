import { useEffect, useMemo, useRef } from "react";
import * as maplibregl from "maplibre-gl";
import { Protocol } from "pmtiles";
import "maplibre-gl/dist/maplibre-gl.css";
import type { LngLat } from "../lib/geo";
import { friendLabel, useFriends, type Spot } from "../lib/spots";
import { fmtClock } from "../lib/spots/timeFmt";
import { hapticTap } from "../lib/native";
import "./spots.css";

const DARK = window.matchMedia("(prefers-color-scheme: dark)").matches;
const STYLE = DARK
  ? "https://tiles.openfreemap.org/styles/dark"
  : "https://tiles.openfreemap.org/styles/positron";

let protocolRegistered = false;

/** Ziel-Pin aus dem Mockup — bottom-anchored, damit die Spitze auf dem Punkt sitzt. */
const TARGET_PIN_SVG =
  '<svg viewBox="0 0 30 40"><path d="M15 39C15 39 3 24.5 3 14a12 12 0 0 1 24 0c0 10.5-12 25-12 25z" fill="#17191C" stroke="#fff" stroke-width="2"/><circle cx="15" cy="14" r="4.5" fill="#fff"/></svg>';

interface Props {
  tilesUrl: string;
  center: LngLat;
  userPos: LngLat | null;
  accuracyM: number;
  timeActive: boolean;
  /** Ziel-Modus: Pin + flyTo, Folgen des Nutzers ist aus. */
  target: LngLat | null;
  /** Persistente Spots — Marker werden per id angelegt/aktualisiert/entfernt. */
  spots: Spot[];
  /** Aktive Einladung pro Spot-Id: Anker-Zeit fürs time-pill („ab 20:00"). */
  sessions: ReadonlyMap<string, number>;
  onSpotTap: (id: string) => void;
  /** Pick-Modus: Karte bleibt frei beweglich (kein Folgen des Pucks). */
  pickCenter?: boolean;
  /** Die Karten-Instanz nach außen — „Auf Karte wählen" braucht getCenter(). */
  onMapInstance?: (map: maplibregl.Map) => void;
  onMapReady?: () => void;
}

export default function MapView({
  tilesUrl,
  center,
  userPos,
  accuracyM,
  timeActive,
  target,
  spots,
  sessions,
  onSpotTap,
  pickCenter,
  onMapInstance,
  onMapReady,
}: Props) {
  const container = useRef<HTMLDivElement>(null);
  const mapRef = useRef<maplibregl.Map | null>(null);
  const markerRef = useRef<maplibregl.Marker | null>(null);
  const targetRef = useRef<maplibregl.Marker | null>(null);
  const spotMarkers = useRef(new Map<string, maplibregl.Marker>());
  const followUser = useRef(true);

  // Der Marker-Listener lebt so lange wie sein DOM-Element; ohne Ref zeigt er
  // auf den Callback des ersten Renders.
  const onSpotTapRef = useRef(onSpotTap);
  useEffect(() => {
    onSpotTapRef.current = onSpotTap;
  }, [onSpotTap]);

  // Untertitel des Tags („mit Marcel, Tara") kommt aus den echten Teilnehmern
  // des jeweiligen Spots — ein rein lokaler Spot hat keine und bleibt stumm.
  const friends = useFriends();
  const friendNames = useMemo(
    () => new Map(friends.map((f) => [f.id, friendLabel(f)])),
    [friends],
  );

  useEffect(() => {
    if (!container.current) return;
    if (!protocolRegistered) {
      maplibregl.addProtocol("pmtiles", new Protocol().tile);
      protocolRegistered = true;
    }

    // Für die Cleanup-Closure festhalten: die Ref-Identität ändert sich nie,
    // aber `.current` darf im Cleanup nicht frisch gelesen werden.
    const markers = spotMarkers.current;
    const map = new maplibregl.Map({
      container: container.current,
      style: STYLE,
      center: [center.lng, center.lat],
      zoom: 14.2,
      attributionControl: { compact: true },
    });
    mapRef.current = map;
    onMapInstance?.(map);

    map.on("dragstart", () => {
      followUser.current = false;
    });

    map.on("load", () => {
      map.addSource("zones", {
        type: "vector",
        url: "pmtiles://" + new URL(tilesUrl, window.location.href).href,
      });
      map.addLayer({
        id: "ban-fill",
        type: "fill",
        source: "zones",
        "source-layer": "ban",
        paint: { "fill-color": "#E5484D", "fill-opacity": DARK ? 0.22 : 0.16 },
      });
      map.addLayer({
        id: "ban-line",
        type: "line",
        source: "zones",
        "source-layer": "ban",
        paint: { "line-color": "#E5484D", "line-width": 1.6, "line-opacity": 0.75 },
      });
      map.addLayer({
        id: "time-fill",
        type: "fill",
        source: "zones",
        "source-layer": "time",
        paint: { "fill-color": "#F76B15", "fill-opacity": timeActive ? (DARK ? 0.22 : 0.16) : 0.07 },
      });
      map.addLayer({
        id: "time-line",
        type: "line",
        source: "zones",
        "source-layer": "time",
        paint: {
          "line-color": "#F76B15",
          "line-width": 1.6,
          "line-dasharray": [2.2, 1.6],
          "line-opacity": timeActive ? 0.85 : 0.4,
        },
      });
      map.once("idle", () => {
        (window as unknown as Record<string, unknown>).__MAP_READY__ = true;
        onMapReady?.();
      });
    });

    return () => {
      map.remove();
      mapRef.current = null;
      markerRef.current = null;
      targetRef.current = null;
      // Die Marker hingen an der zerstörten Karte; ohne Leeren würde der
      // StrictMode-Zweitlauf sie für „schon vorhanden" halten und nie neu setzen.
      markers.clear();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Zeitzustand live nachziehen (Minutenwechsel 7/20 Uhr)
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !map.getLayer("time-fill")) return;
    map.setPaintProperty("time-fill", "fill-opacity", timeActive ? (DARK ? 0.22 : 0.16) : 0.07);
    map.setPaintProperty("time-line", "line-opacity", timeActive ? 0.85 : 0.4);
  }, [timeActive]);

  // User-Puck + sanftes Folgen
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !userPos) return;
    if (!markerRef.current) {
      const el = document.createElement("div");
      el.className = "puck";
      el.innerHTML = '<div class="halo"></div><div class="ring"></div><div class="core"></div>';
      markerRef.current = new maplibregl.Marker({ element: el })
        .setLngLat([userPos.lng, userPos.lat])
        .addTo(map);
    } else {
      markerRef.current.setLngLat([userPos.lng, userPos.lat]);
    }
    const ring = markerRef.current.getElement().querySelector<HTMLElement>(".ring");
    if (ring) {
      const px = Math.min(120, accuracyM / metersPerPixel(map, userPos.lat));
      ring.style.width = ring.style.height = `${Math.max(0, px * 2)}px`;
      ring.style.opacity = px > 14 ? "1" : "0";
    }
    if (followUser.current) {
      map.easeTo({ center: [userPos.lng, userPos.lat], duration: 800 });
    }
  }, [userPos, accuracyM]);

  // Ziel-Pin + Anflug. Ohne Ziel verschwindet der Pin wieder.
  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    if (!target) {
      targetRef.current?.remove();
      targetRef.current = null;
      return;
    }
    followUser.current = false;
    if (!targetRef.current) {
      const el = document.createElement("div");
      el.className = "target-pin";
      el.innerHTML = TARGET_PIN_SVG;
      targetRef.current = new maplibregl.Marker({ element: el, anchor: "bottom" });
    }
    targetRef.current.setLngLat([target.lng, target.lat]).addTo(map);
    // Offset nach oben — sonst deckt das Sheet den Pin halb zu.
    map.flyTo({ center: [target.lng, target.lat], zoom: 15, speed: 1.6, offset: [0, -60] });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [target?.lng, target?.lat]);

  // Im Pick-Modus gehört die Karte dem Nutzer — ein GPS-Update darf ihm den
  // gewählten Ausschnitt nicht unter der Hand wegziehen.
  useEffect(() => {
    if (pickCenter) followUser.current = false;
  }, [pickCenter]);

  // Spot-Marker: anlegen/aktualisieren/entfernen per id.
  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    const live = new Set<string>();

    for (const spot of spots) {
      live.add(spot.id);
      let marker = spotMarkers.current.get(spot.id);
      if (!marker) {
        const el = createSpotElement();
        el.querySelector<HTMLButtonElement>(".sp-badge")?.addEventListener("click", () => {
          hapticTap();
          onSpotTapRef.current(spot.id);
        });
        marker = new maplibregl.Marker({ element: el, anchor: "center" });
        spotMarkers.current.set(spot.id, marker);
        marker.setLngLat([spot.lng, spot.lat]).addTo(map);
      } else {
        marker.setLngLat([spot.lng, spot.lat]);
      }
      const withWhom = (spot.participantIds ?? [])
        .map((id) => friendNames.get(id) ?? "Freund")
        .join(", ");
      updateSpotElement(marker.getElement(), spot, sessions.get(spot.id), withWhom);
    }

    for (const [id, marker] of spotMarkers.current) {
      if (live.has(id)) continue;
      marker.remove();
      spotMarkers.current.delete(id);
    }
  }, [spots, sessions, friendNames]);

  useEffect(() => {
    const recenter = () => {
      followUser.current = true;
      const map = mapRef.current;
      if (map && userPos) map.flyTo({ center: [userPos.lng, userPos.lat], zoom: 15, speed: 1.4 });
    };
    window.addEventListener("gz:recenter", recenter);
    return () => {
      window.removeEventListener("gz:recenter", recenter);
    };
  }, [userPos]);

  return <div ref={container} className="map-root" />;
}

/** Marker-Gerüst nach mockup/invite.html (.spot → sp-spot). */
function createSpotElement(): HTMLDivElement {
  const el = document.createElement("div");
  el.className = "sp-spot";
  // Statisches Gerüst per innerHTML, Nutzertexte ausschließlich per textContent.
  el.innerHTML =
    '<div class="sp-timepill"></div>' +
    '<button type="button" class="sp-badge"></button>' +
    '<div class="sp-tag"><b class="sp-name"></b><span class="sp-sep"> · </span><span class="sp-sub"></span></div>';
  return el;
}

function updateSpotElement(
  el: HTMLElement,
  spot: Spot,
  sessionTime: number | undefined,
  withWhom: string,
): void {
  const badge = el.querySelector<HTMLButtonElement>(".sp-badge");
  if (badge) {
    badge.textContent = spot.emoji;
    badge.setAttribute("aria-label", `Spot ${spot.name}`);
  }
  const name = el.querySelector<HTMLElement>(".sp-name");
  if (name) name.textContent = spot.name;

  // Läuft eine Einladung, zeigt der Tag ihre Anker-Zeit statt der Runde.
  const sub = sessionTime !== undefined ? `ab ${fmtClock(sessionTime)}` : withWhom ? `mit ${withWhom}` : "";
  const subEl = el.querySelector<HTMLElement>(".sp-sub");
  if (subEl) subEl.textContent = sub;
  const sep = el.querySelector<HTMLElement>(".sp-sep");
  if (sep) sep.style.display = sub ? "" : "none";

  const pill = el.querySelector<HTMLElement>(".sp-timepill");
  if (pill && sessionTime !== undefined) pill.textContent = `ab ${fmtClock(sessionTime)}`;
  el.classList.toggle("sp-session", sessionTime !== undefined);
}

function metersPerPixel(map: maplibregl.Map, lat: number): number {
  return (40075016.686 * Math.cos((lat * Math.PI) / 180)) / (256 * 2 ** map.getZoom());
}
