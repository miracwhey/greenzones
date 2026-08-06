import { useEffect, useRef } from "react";
import * as maplibregl from "maplibre-gl";
import { Protocol } from "pmtiles";
import "maplibre-gl/dist/maplibre-gl.css";
import type { LngLat } from "../lib/geo";

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
  onMapReady?: () => void;
}

export default function MapView({
  tilesUrl,
  center,
  userPos,
  accuracyM,
  timeActive,
  target,
  onMapReady,
}: Props) {
  const container = useRef<HTMLDivElement>(null);
  const mapRef = useRef<maplibregl.Map | null>(null);
  const markerRef = useRef<maplibregl.Marker | null>(null);
  const targetRef = useRef<maplibregl.Marker | null>(null);
  const followUser = useRef(true);

  useEffect(() => {
    if (!container.current) return;
    if (!protocolRegistered) {
      maplibregl.addProtocol("pmtiles", new Protocol().tile);
      protocolRegistered = true;
    }

    const map = new maplibregl.Map({
      container: container.current,
      style: STYLE,
      center: [center.lng, center.lat],
      zoom: 14.2,
      attributionControl: { compact: true },
    });
    mapRef.current = map;

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

function metersPerPixel(map: maplibregl.Map, lat: number): number {
  return (40075016.686 * Math.cos((lat * Math.PI) / 180)) / (256 * 2 ** map.getZoom());
}
