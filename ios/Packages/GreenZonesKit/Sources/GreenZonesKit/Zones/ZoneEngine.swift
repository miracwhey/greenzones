import CoreLocation
import Foundation
import os

/// Port von `client/src/lib/zones.ts`.
///
/// Liest `zones.pmtiles` selbst — unabhaengig vom Karten-Renderer, damit der
/// Status auch ausserhalb des Viewports, zoom-unabhaengig und offline stimmt
/// (SPEC E6). Die Zahlen muessen mit v1 uebereinstimmen; der Vektor-Test ist
/// der Beweis, nicht die Absicht.
public actor ZoneEngine {
    /// Zonen liegen als z14 im Archiv.
    public static let zoom = 14
    /// Nur Zonen im Umkreis interessieren — haelt Berechnung und Sheet relevant.
    public static let searchRadiusM: Double = 2000
    private static let cacheLimit = 32
    private static let layerNames: Set<String> = ["ban", "time"]

    private let archive: PMTilesArchive
    private let logger = Logger(subsystem: "de.leonvalentin.greenzones", category: "zones")

    private struct TileZones {
        var ban: [GZPolygon] = []
        var time: [GZPolygon] = []
    }

    private var tileCache: [String: TileZones] = [:]
    /// Einfuege-Reihenfolge wie die JS-`Map` — der aelteste Eintrag faellt raus.
    private var cacheOrder: [String] = []

    public init(pmtilesURL: URL) throws {
        archive = try PMTilesArchive(url: pmtilesURL)
    }

    /// Status an einer Position — laedt das 3×3-Kachelfenster um den Punkt.
    public func status(at coordinate: CLLocationCoordinate2D) -> ZoneStatus {
        let (tileX, tileY) = Self.lngLatToTile(coordinate, z: Self.zoom)

        var tiles: [TileZones] = []
        tiles.reserveCapacity(9)
        for dx in -1...1 {
            for dy in -1...1 {
                tiles.append(loadTile(x: tileX + dx, y: tileY + dy))
            }
        }

        var banInside = false
        var banNearest = Double.infinity
        var timeInside = false
        var timeNearest = Double.infinity

        for layer in 0..<2 {
            var inside = false
            var nearest = Double.infinity
            outer: for tile in tiles {
                for polygon in (layer == 0 ? tile.ban : tile.time) {
                    if !inside, Geo.pointInPolygon(coordinate, polygon) {
                        inside = true
                        nearest = 0
                        break outer
                    }
                    let distance = Geo.distToPolygonEdgeM(coordinate, polygon)
                    if distance < nearest { nearest = distance }
                }
            }
            if nearest > Self.searchRadiusM { nearest = .infinity }
            if layer == 0 {
                banInside = inside
                banNearest = nearest
            } else {
                timeInside = inside
                timeNearest = nearest
            }
        }

        return ZoneStatus(ban: LayerStatus(inside: banInside, nearestM: banNearest),
                          time: LayerStatus(inside: timeInside, nearestM: timeNearest))
    }

    // MARK: - Kacheln

    private func loadTile(x: Int, y: Int) -> TileZones {
        let key = "\(x)/\(y)"
        if let cached = tileCache[key] { return cached }

        let zones = fetchTile(x: x, y: y)
        tileCache[key] = zones
        cacheOrder.append(key)
        // Cache klein halten — der Nutzer bewegt sich, alte Kacheln fliegen raus.
        if cacheOrder.count > Self.cacheLimit {
            let oldest = cacheOrder.removeFirst()
            tileCache[oldest] = nil
        }
        return zones
    }

    private func fetchTile(x: Int, y: Int) -> TileZones {
        var out = TileZones()
        do {
            guard let raw = try archive.tile(z: Self.zoom, x: x, y: y) else { return out }
            for layer in try MVTDecoder.decode(raw, only: Self.layerNames) {
                for feature in layer.features {
                    let polygons = MVTDecoder.polygons(feature, x: x, y: y, z: Self.zoom,
                                                       extent: layer.extent)
                    if layer.name == "ban" {
                        out.ban.append(contentsOf: polygons)
                    } else if layer.name == "time" {
                        out.time.append(contentsOf: polygons)
                    }
                }
            }
        } catch {
            // Fehlende oder kaputte Kachel = keine Zonen in diesem Ausschnitt,
            // nicht „kein Status" — v1 faengt genauso ab.
            logger.error("Kachel \(x)/\(y) nicht lesbar: \(String(describing: error))")
        }
        return out
    }

    /// Web-Mercator-Kachelindex, identisch zu `lngLatToTile` in zones.ts.
    public static func lngLatToTile(_ p: CLLocationCoordinate2D, z: Int) -> (x: Int, y: Int) {
        let n = pow(2.0, Double(z))
        let x = Int(floor((p.longitude + 180) / 360 * n))
        let latRad = p.latitude * Double.pi / 180
        let y = Int(floor((1 - log(tan(latRad) + 1 / cos(latRad)) / Double.pi) / 2 * n))
        return (x, y)
    }
}
