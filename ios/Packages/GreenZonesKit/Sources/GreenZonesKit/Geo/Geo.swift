import CoreLocation
import Foundation

/// Port von `client/src/lib/geo.ts` — equirektangulare Naeherung, reicht fuer
/// Distanzen < 2 km. Die Formeln sind absichtlich Zeichen fuer Zeichen dieselben
/// wie in v1: der Vektor-Test vergleicht auf 1,5 m genau, jede „Verbesserung"
/// waere eine Abweichung.

/// Ein Ring liegt flach als `[lng, lat, lng, lat, …]` im Speicher — ein
/// `[[Double]]` je Punkt kostet in Hannover-Tiles fuenfstellig viele
/// Array-Allokationen pro Kachel.
public typealias GZRing = [Double]
/// Polygon: Ring 0 ist die Aussenkante, alle weiteren sind Loecher.
public typealias GZPolygon = [GZRing]

public enum Geo {
    static let earthRadiusM = 6_371_000.0
    static let deg = Double.pi / 180

    /// Meter-Distanz zweier Punkte (equirektangular).
    public static func distanceM(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let x = (b.longitude - a.longitude) * deg * cos((a.latitude + b.latitude) / 2 * deg)
        let y = (b.latitude - a.latitude) * deg
        return (x * x + y * y).squareRoot() * earthRadiusM
    }

    /// de-DE-Distanz: unter 1 km „650 m", darueber „2,1 km".
    public static func formatDistanceM(_ m: Double) -> String {
        if m >= 1000 {
            // `toFixed(1)` rundet kaufmaennisch — `String(format:)` tut dasselbe.
            let km = String(format: "%.1f", m / 1000).replacingOccurrences(of: ".", with: ",")
            return km + " km"
        }
        return "\(Int(m.rounded())) m"
    }

    /// Punkt-in-Ring (Ray-Casting).
    static func inRing(_ p: CLLocationCoordinate2D, _ ring: GZRing) -> Bool {
        var inside = false
        let count = ring.count / 2
        guard count > 0 else { return false }
        var j = count - 1
        for i in 0..<count {
            let xi = ring[2 * i], yi = ring[2 * i + 1]
            let xj = ring[2 * j], yj = ring[2 * j + 1]
            if (yi > p.latitude) != (yj > p.latitude),
               p.longitude < (xj - xi) * (p.latitude - yi) / (yj - yi) + xi {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Punkt in Polygon (aeusserer Ring minus Loecher).
    public static func pointInPolygon(_ p: CLLocationCoordinate2D, _ polygon: GZPolygon) -> Bool {
        guard let outer = polygon.first, inRing(p, outer) else { return false }
        for i in 1..<max(polygon.count, 1) where inRing(p, polygon[i]) {
            return false
        }
        return true
    }

    /// Kuerzeste Meter-Distanz Punkt → Segment (in lokaler Meter-Projektion).
    static func distToSegmentM(px: Double, py: Double, cosLat: Double,
                               ax0: Double, ay0: Double, bx0: Double, by0: Double) -> Double {
        let ax = (ax0 - px) * deg * cosLat * earthRadiusM
        let ay = (ay0 - py) * deg * earthRadiusM
        let bx = (bx0 - px) * deg * cosLat * earthRadiusM
        let by = (by0 - py) * deg * earthRadiusM
        let dx = bx - ax
        let dy = by - ay
        let len2 = dx * dx + dy * dy
        let t = len2 == 0 ? 0 : max(0, min(1, -(ax * dx + ay * dy) / len2))
        let cx = ax + t * dx
        let cy = ay + t * dy
        return (cx * cx + cy * cy).squareRoot()
    }

    /// Kuerzeste Meter-Distanz Punkt → Polygonkante (alle Ringe).
    public static func distToPolygonEdgeM(_ p: CLLocationCoordinate2D, _ polygon: GZPolygon) -> Double {
        var minimum = Double.infinity
        let cosLat = cos(p.latitude * deg)
        for ring in polygon {
            let count = ring.count / 2
            guard count >= 2 else { continue }
            // Wie v1: bis `count - 1`, der schliessende Doppelpunkt der MVT-Ringe
            // liefert das letzte Segment.
            for i in 0..<(count - 1) {
                let d = distToSegmentM(px: p.longitude, py: p.latitude, cosLat: cosLat,
                                       ax0: ring[2 * i], ay0: ring[2 * i + 1],
                                       bx0: ring[2 * i + 2], by0: ring[2 * i + 3])
                if d < minimum { minimum = d }
            }
        }
        return minimum
    }
}
