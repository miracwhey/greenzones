/**
 * Zonen-Engine — liest zones.pmtiles direkt (kartenunabhängig).
 * Für eine Position werden die umliegenden z14-Tiles geladen, ban/time-Layer
 * geparst und Inside/Distanz berechnet. Funktioniert offline mit gebundelter Datei.
 */
import { PMTiles } from "pmtiles";
import { VectorTile } from "@mapbox/vector-tile";
import { PbfReader } from "pbf";
import { distToPolygonEdgeM, pointInPolygon, type LngLat } from "./geo";

const Z = 14;
/** Nur Zonen im Umkreis interessieren — hält Berechnung und Sheet relevant. */
export const SEARCH_RADIUS_M = 2000;

export interface LayerStatus {
  inside: boolean;
  /** Meter bis zur nächsten Zonenkante; Infinity wenn keine im Suchradius. 0 wenn inside. */
  nearestM: number;
}

export interface ZoneStatus {
  ban: LayerStatus;
  time: LayerStatus;
}

function lngLatToTile(lng: number, lat: number, z: number) {
  const n = 2 ** z;
  const x = Math.floor(((lng + 180) / 360) * n);
  const latRad = (lat * Math.PI) / 180;
  const y = Math.floor(((1 - Math.log(Math.tan(latRad) + 1 / Math.cos(latRad)) / Math.PI) / 2) * n);
  return { x, y };
}

type PolyCoords = number[][][];

interface TileZones {
  ban: PolyCoords[];
  time: PolyCoords[];
}

export class ZoneEngine {
  private pm: PMTiles;
  private tileCache = new Map<string, Promise<TileZones>>();

  constructor(url: string) {
    this.pm = new PMTiles(url);
  }

  private async loadTile(x: number, y: number): Promise<TileZones> {
    const key = `${x}/${y}`;
    let cached = this.tileCache.get(key);
    if (!cached) {
      cached = this.fetchTile(x, y);
      this.tileCache.set(key, cached);
      // Cache klein halten — Nutzer bewegt sich, alte Tiles fliegen raus
      if (this.tileCache.size > 32) {
        const oldest = this.tileCache.keys().next().value;
        if (oldest) this.tileCache.delete(oldest);
      }
    }
    return cached;
  }

  private async fetchTile(x: number, y: number): Promise<TileZones> {
    const res = await this.pm.getZxy(Z, x, y);
    const out: TileZones = { ban: [], time: [] };
    if (!res?.data) return out;
    const vt = new VectorTile(new PbfReader(res.data));
    for (const name of ["ban", "time"] as const) {
      const layer = vt.layers[name];
      if (!layer) continue;
      for (let i = 0; i < layer.length; i++) {
        const geom = layer.feature(i).toGeoJSON(x, y, Z).geometry;
        if (geom.type === "Polygon") out[name].push(geom.coordinates as PolyCoords);
        else if (geom.type === "MultiPolygon") {
          for (const c of geom.coordinates) out[name].push(c as PolyCoords);
        }
      }
    }
    return out;
  }

  /** Status an Position — lädt 3×3-Tile-Fenster um den Punkt. */
  async status(p: LngLat): Promise<ZoneStatus> {
    const { x, y } = lngLatToTile(p.lng, p.lat, Z);
    const tiles = await Promise.all(
      [-1, 0, 1].flatMap((dx) =>
        [-1, 0, 1].map((dy) => this.loadTile(x + dx, y + dy).catch((): TileZones => ({ ban: [], time: [] }))),
      ),
    );

    const result: ZoneStatus = {
      ban: { inside: false, nearestM: Infinity },
      time: { inside: false, nearestM: Infinity },
    };

    for (const name of ["ban", "time"] as const) {
      const s = result[name];
      for (const tile of tiles) {
        for (const poly of tile[name]) {
          if (!s.inside && pointInPolygon(p, poly)) {
            s.inside = true;
            s.nearestM = 0;
            break;
          }
          const d = distToPolygonEdgeM(p, poly);
          if (d < s.nearestM) s.nearestM = d;
        }
        if (s.inside) break;
      }
      if (s.nearestM > SEARCH_RADIUS_M) s.nearestM = Infinity;
    }
    return result;
  }
}
