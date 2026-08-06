/** Schlanke Geo-Utils — equirektangulare Näherung reicht für <2 km Distanzen. */

export interface LngLat {
  lng: number;
  lat: number;
}

const R = 6371000;
const DEG = Math.PI / 180;

/** Meter-Distanz zweier Punkte (equirektangular). */
export function distanceM(a: LngLat, b: LngLat): number {
  const x = (b.lng - a.lng) * DEG * Math.cos(((a.lat + b.lat) / 2) * DEG);
  const y = (b.lat - a.lat) * DEG;
  return Math.sqrt(x * x + y * y) * R;
}

/** de-DE-Distanz: unter 1 km "650 m", darüber "2,1 km". */
export function formatDistanceM(m: number): string {
  return m >= 1000 ? (m / 1000).toFixed(1).replace(".", ",") + " km" : Math.round(m) + " m";
}

/** Punkt-in-Ring (Ray-Casting), Ring = [[lng,lat],...]. */
function inRing(p: LngLat, ring: number[][]): boolean {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i];
    const [xj, yj] = ring[j];
    if (yi > p.lat !== yj > p.lat && p.lng < ((xj - xi) * (p.lat - yi)) / (yj - yi) + xi) {
      inside = !inside;
    }
  }
  return inside;
}

/** Punkt in Polygon (äußerer Ring minus Löcher). coordinates = Polygon-Koordinaten. */
export function pointInPolygon(p: LngLat, coordinates: number[][][]): boolean {
  if (!coordinates.length || !inRing(p, coordinates[0])) return false;
  for (let i = 1; i < coordinates.length; i++) {
    if (inRing(p, coordinates[i])) return false;
  }
  return true;
}

/** Kürzeste Meter-Distanz Punkt → Segment (in lokaler Meter-Projektion). */
function distToSegmentM(p: LngLat, a: number[], b: number[]): number {
  const cos = Math.cos(p.lat * DEG);
  const ax = (a[0] - p.lng) * DEG * cos * R;
  const ay = (a[1] - p.lat) * DEG * R;
  const bx = (b[0] - p.lng) * DEG * cos * R;
  const by = (b[1] - p.lat) * DEG * R;
  const dx = bx - ax;
  const dy = by - ay;
  const len2 = dx * dx + dy * dy;
  const t = len2 === 0 ? 0 : Math.max(0, Math.min(1, -(ax * dx + ay * dy) / len2));
  const cx = ax + t * dx;
  const cy = ay + t * dy;
  return Math.sqrt(cx * cx + cy * cy);
}

/** Kürzeste Meter-Distanz Punkt → Polygonkante (alle Ringe). */
export function distToPolygonEdgeM(p: LngLat, coordinates: number[][][]): number {
  let min = Infinity;
  for (const ring of coordinates) {
    for (let i = 0; i < ring.length - 1; i++) {
      const d = distToSegmentM(p, ring[i], ring[i + 1]);
      if (d < min) min = d;
    }
  }
  return min;
}
