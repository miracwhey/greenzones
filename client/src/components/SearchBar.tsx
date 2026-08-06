import { useEffect, useRef, useState } from "react";
import { hapticTap } from "../lib/native";

interface Result {
  name: string;
  detail: string;
  lng: number;
  lat: number;
}

/** Photon (OSM-Geocoder, gratis) — auf Deutschland begrenzt. */
async function geocode(q: string, signal: AbortSignal): Promise<Result[]> {
  const url =
    "https://photon.komoot.io/api/?limit=5&lang=de&bbox=5.8,47.2,15.1,55.1&q=" + encodeURIComponent(q);
  const res = await fetch(url, { signal });
  if (!res.ok) return [];
  const data = await res.json();
  return (data.features ?? []).map((f: GeoJSON.Feature) => {
    const p = (f.properties ?? {}) as Record<string, string>;
    const [lng, lat] = (f.geometry as GeoJSON.Point).coordinates;
    return {
      name: p.name ?? p.street ?? "Unbenannt",
      detail: [p.postcode, p.city ?? p.county, p.state].filter(Boolean).join(", "),
      lng,
      lat,
    };
  });
}

export default function SearchBar() {
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<Result[]>([]);
  const [focused, setFocused] = useState(false);
  const abortRef = useRef<AbortController | null>(null);

  useEffect(() => {
    abortRef.current?.abort();
    if (query.trim().length < 3) {
      setResults([]);
      return;
    }
    const ctl = new AbortController();
    abortRef.current = ctl;
    const t = setTimeout(() => {
      geocode(query, ctl.signal)
        .then(setResults)
        .catch(() => {});
    }, 250);
    return () => clearTimeout(t);
  }, [query]);

  const go = (r: Result) => {
    hapticTap();
    window.dispatchEvent(new CustomEvent("gz:goto", { detail: { lng: r.lng, lat: r.lat } }));
    setQuery("");
    setResults([]);
    (document.activeElement as HTMLElement | null)?.blur();
  };

  const open = focused && results.length > 0;

  return (
    <div className={`search-wrap ${open ? "open" : ""}`}>
      <div className="search glass">
        <svg viewBox="0 0 24 24">
          <circle cx="11" cy="11" r="7" />
          <path d="m20 20-3.8-3.8" />
        </svg>
        <input
          type="search"
          placeholder="Ort oder Adresse suchen"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          onFocus={() => setFocused(true)}
          onBlur={() => setTimeout(() => setFocused(false), 150)}
          enterKeyHint="search"
          autoCorrect="off"
        />
      </div>
      {open && (
        <div className="search-results glass">
          {results.map((r, i) => (
            <button key={i} className="search-row" onClick={() => go(r)}>
              <b>{r.name}</b>
              <span>{r.detail}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
