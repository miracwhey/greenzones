import { useEffect, useRef, useState } from "react";
import { Geolocation } from "@capacitor/geolocation";
import type { LngLat } from "./geo";

export type LocationState =
  | { kind: "idle" }
  | { kind: "locating" }
  | { kind: "ready"; pos: LngLat; accuracyM: number }
  | { kind: "denied" }
  | { kind: "error"; message: string };

const params = new URLSearchParams(window.location.search);
const debugPos: LngLat | null =
  params.has("lat") && params.has("lng")
    ? { lat: parseFloat(params.get("lat")!), lng: parseFloat(params.get("lng")!) }
    : null;

/** Live-Standort (watch). Debug-Override via ?lat=&lng=. */
export function useLocation(enabled: boolean): LocationState {
  const [state, setState] = useState<LocationState>({ kind: "idle" });
  const watchId = useRef<string | null>(null);

  useEffect(() => {
    if (!enabled) return;
    if (debugPos) {
      setState({ kind: "ready", pos: debugPos, accuracyM: 12 });
      return;
    }
    let cancelled = false;
    setState({ kind: "locating" });

    // watchPosition allein prompted nicht: ein CLLocationManager ohne
    // Authorization liefert nie eine Position und nie einen Fehler — der
    // Zustand bliebe ewig „locating" (z. B. nach iOS-Datenschutz-Reset,
    // Onboarding längst durch). Deshalb Permission explizit klären.
    const ensurePermission = async (): Promise<"ok" | "denied"> => {
      try {
        let status = await Geolocation.checkPermissions();
        if (status.location === "prompt" || status.location === "prompt-with-rationale") {
          status = await Geolocation.requestPermissions();
        }
        return status.location === "denied" ? "denied" : "ok";
      } catch {
        // Web kennt requestPermissions nicht — der Browser prompted selbst.
        return "ok";
      }
    };

    ensurePermission().then((perm) => {
      if (cancelled) return;
      if (perm === "denied") {
        setState({ kind: "denied" });
        return;
      }
      void Geolocation.watchPosition(
        { enableHighAccuracy: true, timeout: 15000, maximumAge: 5000 },
        (position, err) => {
          if (cancelled) return;
          if (err || !position) {
            const message = err?.message ?? "Standort nicht verfügbar";
            setState(
              /denied|permission/i.test(message) ? { kind: "denied" } : { kind: "error", message },
            );
            return;
          }
          setState({
            kind: "ready",
            pos: { lng: position.coords.longitude, lat: position.coords.latitude },
            accuracyM: position.coords.accuracy ?? 50,
          });
        },
      ).then((id) => {
        watchId.current = id;
        if (cancelled) void Geolocation.clearWatch({ id });
      });
    });

    return () => {
      cancelled = true;
      if (watchId.current) void Geolocation.clearWatch({ id: watchId.current });
    };
  }, [enabled]);

  return state;
}
