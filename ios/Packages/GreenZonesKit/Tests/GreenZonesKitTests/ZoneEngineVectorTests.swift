import CoreLocation
import Foundation
import Testing
@testable import GreenZonesKit

/// Der Paritaetsbeweis der Engine (SPEC 6).
///
/// Die Vektoren stammen aus `client/scripts/export_zone_vectors.mjs`, das die
/// UNVERAENDERTE v1-Engine gegen dieselbe `zones.pmtiles` laufen laesst. `inside`
/// muss exakt stimmen, `nearestM` auf 1,5 m, Infinity exakt. Wird das verfehlt,
/// ist der Port falsch — nicht die Toleranz.
@Suite("ZoneEngine — Vektor-Paritaet gegen v1")
struct ZoneEngineVectorTests {
    static let tolerance = 1.5

    @Test("Alle Vektoren aus zone_vectors.json stimmen")
    func parity() async throws {
        let data = try Data(contentsOf: TestPaths.zoneVectors)
        let file = try JSONDecoder().decode(ZoneVectorFile.self, from: data)
        #expect(file.points.count == file.count)
        #expect(file.points.count >= 300, "SPEC verlangt mindestens 300 Vektoren")

        let engine = try ZoneEngine(pmtilesURL: TestPaths.zonesPMTiles)

        var maxBanDelta = 0.0
        var maxTimeDelta = 0.0
        var insideMismatches: [String] = []
        var distanceMismatches: [String] = []

        for point in file.points {
            let coordinate = CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng)
            let status = await engine.status(at: coordinate)

            func check(_ name: String, _ expected: ZoneVector.Layer, _ actual: LayerStatus,
                       maxDelta: inout Double) {
                if expected.inside != actual.inside {
                    insideMismatches.append(
                        "\(name) @ \(point.lat)/\(point.lng) [\(point.note)]: " +
                        "v1=\(expected.inside) swift=\(actual.inside)")
                }
                guard let expectedM = expected.nearestM else {
                    if actual.nearestM.isFinite {
                        distanceMismatches.append(
                            "\(name) @ \(point.lat)/\(point.lng): v1=∞ swift=\(actual.nearestM)")
                    }
                    return
                }
                guard actual.nearestM.isFinite else {
                    distanceMismatches.append(
                        "\(name) @ \(point.lat)/\(point.lng): v1=\(expectedM) swift=∞")
                    return
                }
                let delta = abs(expectedM - actual.nearestM)
                if delta > maxDelta { maxDelta = delta }
                if delta > Self.tolerance {
                    distanceMismatches.append(
                        "\(name) @ \(point.lat)/\(point.lng) [\(point.note)]: " +
                        "v1=\(expectedM) swift=\(actual.nearestM) Δ=\(delta)")
                }
            }

            check("ban", point.ban, status.ban, maxDelta: &maxBanDelta)
            check("time", point.time, status.time, maxDelta: &maxTimeDelta)
        }

        // Die Zahlen gehoeren in die Ausgabe, nicht nur ins Urteil.
        print("[vektoren] \(file.points.count) Punkte · maxΔ ban = " +
              "\(String(format: "%.4f", maxBanDelta)) m · maxΔ time = " +
              "\(String(format: "%.4f", maxTimeDelta)) m")

        if !insideMismatches.isEmpty {
            print("[vektoren] inside weicht ab:\n" + insideMismatches.prefix(10).joined(separator: "\n"))
        }
        if !distanceMismatches.isEmpty {
            print("[vektoren] nearestM weicht ab:\n" + distanceMismatches.prefix(10).joined(separator: "\n"))
        }
        #expect(insideMismatches.isEmpty)
        #expect(distanceMismatches.isEmpty)
        #expect(maxBanDelta <= Self.tolerance)
        #expect(maxTimeDelta <= Self.tolerance)
    }

    @Test("Vektoren decken beide Ebenen und beide Urteile ab")
    func coverage() throws {
        let data = try Data(contentsOf: TestPaths.zoneVectors)
        let file = try JSONDecoder().decode(ZoneVectorFile.self, from: data)
        // Ein Vektorsatz ohne Innen-Punkte wuerde `inside` nie pruefen.
        #expect(file.points.contains { $0.ban.inside })
        #expect(file.points.contains { $0.time.inside })
        #expect(file.points.contains { !$0.ban.inside && $0.ban.nearestM != nil })
        #expect(file.points.contains { !$0.time.inside && $0.time.nearestM != nil })
        #expect(file.points.contains { $0.note.hasPrefix("rand-") })
        // …und ohne Weitpunkte bliebe `nearestM > 2000 → Infinity` ungeprueft.
        #expect(file.points.contains { $0.ban.nearestM == nil })
        #expect(file.points.contains { $0.time.nearestM == nil })
        // Gemischter Fall: eine Ebene endlich, die andere unendlich.
        #expect(file.points.contains { $0.ban.nearestM != nil && $0.time.nearestM == nil })
    }

    @Test("Kachelindex und Suchradius entsprechen v1")
    func engineConstants() async throws {
        #expect(ZoneEngine.zoom == 14)
        #expect(ZoneEngine.searchRadiusM == 2000)

        let kroepcke = CLLocationCoordinate2D(latitude: 52.3745, longitude: 9.7386)
        let tile = ZoneEngine.lngLatToTile(kroepcke, z: 14)
        #expect(tile.x == 8635)
        #expect(tile.y == 5384)

        // Mitten im Atlantik: keine Zone, kein Absturz.
        let engine = try ZoneEngine(pmtilesURL: TestPaths.zonesPMTiles)
        let empty = await engine.status(at: CLLocationCoordinate2D(latitude: 30, longitude: -40))
        #expect(!empty.ban.inside)
        #expect(!empty.time.inside)
        #expect(empty.ban.nearestM == .infinity)
        #expect(empty.time.nearestM == .infinity)
    }
}
