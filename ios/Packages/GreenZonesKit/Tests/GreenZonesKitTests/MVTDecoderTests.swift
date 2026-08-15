import CoreLocation
import Foundation
import Testing
@testable import GreenZonesKit

/// Baut Protobuf-Bytes von Hand — der Dekoder wird gegen eine Kachel geprueft,
/// deren Inhalt hier vollstaendig festgelegt ist, nicht gegen sich selbst.
private struct PBWriter {
    private(set) var bytes: [UInt8] = []

    mutating func varint(_ value: UInt64) {
        var v = value
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while v != 0
    }

    mutating func tag(field: Int, wire: Int) {
        varint(UInt64(field << 3 | wire))
    }

    mutating func lengthDelimited(field: Int, _ payload: [UInt8]) {
        tag(field: field, wire: 2)
        varint(UInt64(payload.count))
        bytes.append(contentsOf: payload)
    }

    mutating func varintField(field: Int, _ value: UInt64) {
        tag(field: field, wire: 0)
        varint(value)
    }

    static func zigzag(_ value: Int) -> UInt64 {
        UInt64(bitPattern: Int64((value << 1) ^ (value >> 63)))
    }
}

@Suite("MVTDecoder — Mapbox Vector Tile 2.1")
struct MVTDecoderTests {
    /// Aussenring (0,0)-(10,10) im Uhrzeigersinn plus gegenlaeufiges Loch
    /// (2,2)-(8,8). Kommandos: MoveTo, 3× LineTo, ClosePath — zweimal.
    private func syntheticTile(layerName: String = "ban", extent: Int = 4096) -> Data {
        var geometry = PBWriter()
        // Aussenring
        geometry.varint(UInt64(1 << 3 | 1))                 // MoveTo, 1×
        geometry.varint(PBWriter.zigzag(0)); geometry.varint(PBWriter.zigzag(0))
        geometry.varint(UInt64(3 << 3 | 2))                 // LineTo, 3×
        geometry.varint(PBWriter.zigzag(10)); geometry.varint(PBWriter.zigzag(0))
        geometry.varint(PBWriter.zigzag(0)); geometry.varint(PBWriter.zigzag(10))
        geometry.varint(PBWriter.zigzag(-10)); geometry.varint(PBWriter.zigzag(0))
        geometry.varint(UInt64(1 << 3 | 7))                 // ClosePath
        // Loch — der Cursor steht nach ClosePath auf (0,10).
        geometry.varint(UInt64(1 << 3 | 1))
        geometry.varint(PBWriter.zigzag(2)); geometry.varint(PBWriter.zigzag(-8))
        geometry.varint(UInt64(3 << 3 | 2))
        geometry.varint(PBWriter.zigzag(0)); geometry.varint(PBWriter.zigzag(6))
        geometry.varint(PBWriter.zigzag(6)); geometry.varint(PBWriter.zigzag(0))
        geometry.varint(PBWriter.zigzag(0)); geometry.varint(PBWriter.zigzag(-6))
        geometry.varint(UInt64(1 << 3 | 7))

        var feature = PBWriter()
        feature.varintField(field: 1, 42)                   // id
        feature.lengthDelimited(field: 2, [0x00, 0x00])     // tags — muessen uebersprungen werden
        feature.varintField(field: 3, 3)                    // type = POLYGON
        feature.lengthDelimited(field: 4, geometry.bytes)

        var layer = PBWriter()
        layer.varintField(field: 15, 2)                     // version
        layer.lengthDelimited(field: 1, Array(layerName.utf8))
        layer.lengthDelimited(field: 2, feature.bytes)
        layer.lengthDelimited(field: 3, Array("dummy".utf8)) // keys — uebersprungen
        layer.varintField(field: 5, UInt64(extent))

        var tile = PBWriter()
        tile.lengthDelimited(field: 3, layer.bytes)
        return Data(tile.bytes)
    }

    @Test("Layer, extent und Ringe kommen vollstaendig an")
    func decodeSynthetic() throws {
        let layers = try MVTDecoder.decode(syntheticTile())
        #expect(layers.count == 1)
        let layer = try #require(layers.first)
        #expect(layer.name == "ban")
        #expect(layer.extent == 4096)
        #expect(layer.features.count == 1)

        let feature = try #require(layer.features.first)
        #expect(feature.type == .polygon)
        #expect(feature.rings.count == 2)
        // ClosePath haengt den Startpunkt an: 5 Punkte je Ring.
        #expect(feature.rings[0] == [0, 0, 10, 0, 10, 10, 0, 10, 0, 0])
        #expect(feature.rings[1] == [2, 2, 2, 8, 8, 8, 8, 2, 2, 2])
    }

    @Test("Layer-Filter parst fremde Layer nicht mit")
    func layerFilter() throws {
        #expect(try MVTDecoder.decode(syntheticTile(layerName: "roads"),
                                      only: ["ban", "time"]).isEmpty)
        #expect(try MVTDecoder.decode(syntheticTile(layerName: "time"),
                                      only: ["ban", "time"]).count == 1)
    }

    @Test("Ring-Orientierung: gegenlaeufiger Ring wird zum Loch")
    func ringOrientation() throws {
        let layers = try MVTDecoder.decode(syntheticTile())
        let feature = try #require(layers.first?.features.first)
        #expect(MVTDecoder.signedArea(feature.rings[0]) > 0)
        #expect(MVTDecoder.signedArea(feature.rings[1]) < 0)

        let grouped = MVTDecoder.classifyRings(feature.rings)
        #expect(grouped.count == 1)
        #expect(grouped[0].count == 2)
    }

    @Test("Zwei gleich orientierte Ringe werden zwei Polygone")
    func twoPolygons() {
        let a: [Double] = [0, 0, 10, 0, 10, 10, 0, 10, 0, 0]
        let b: [Double] = [20, 20, 30, 20, 30, 30, 20, 30, 20, 20]
        let grouped = MVTDecoder.classifyRings([a, b])
        #expect(grouped.count == 2)
        #expect(grouped[0].count == 1)
        #expect(grouped[1].count == 1)
    }

    @Test("Projektion Kachel → lng/lat entspricht toGeoJSON")
    func projection() throws {
        let layers = try MVTDecoder.decode(syntheticTile())
        let feature = try #require(layers.first?.features.first)
        let polygons = MVTDecoder.polygons(feature, x: 0, y: 0, z: 0, extent: 4096)
        #expect(polygons.count == 1)
        #expect(polygons[0].count == 2)

        // (0,0) der Welt-Kachel z0 ist die linke obere Mercator-Ecke.
        #expect(abs(polygons[0][0][0] - (-180)) < 1e-9)
        #expect(abs(polygons[0][0][1] - 85.0511287798066) < 1e-9)

        // Gegenprobe mit der Kachel, in der Kroepcke liegt: die linke obere Ecke
        // muss knapp neben dem Punkt landen, aus dem der Kachelindex stammt.
        let kroepcke = CLLocationCoordinate2D(latitude: 52.3745, longitude: 9.7386)
        let tile = ZoneEngine.lngLatToTile(kroepcke, z: 14)
        let projected = MVTDecoder.polygons(feature, x: tile.x, y: tile.y, z: 14, extent: 4096)
        let corner = projected[0][0]
        // Eine z14-Kachel ist in Hannover ~1,5 km breit — die Ecke liegt also
        // suedwestlich/nordwestlich des Punktes, aber innerhalb einer Kachelbreite.
        #expect(corner[0] <= kroepcke.longitude)
        #expect(kroepcke.longitude - corner[0] < 360 / 16384)
        #expect(corner[1] >= kroepcke.latitude)
        #expect(corner[1] - kroepcke.latitude < 0.02)
    }

    @Test("Nicht-Polygon-Features liefern keine Flaechen")
    func nonPolygon() {
        let line = MVTFeature(type: .lineString, rings: [[0, 0, 10, 10]])
        #expect(MVTDecoder.polygons(line, x: 0, y: 0, z: 0, extent: 4096).isEmpty)
    }

    @Test("Unbekanntes Geometrie-Kommando wird gemeldet, nicht verschluckt")
    func badCommand() {
        var geometry = PBWriter()
        geometry.varint(UInt64(1 << 3 | 4)) // Kommando 4 gibt es nicht
        #expect(throws: MVTError.unknownGeometryCommand(4)) {
            _ = try MVTDecoder.decodeGeometry(Data(geometry.bytes))
        }
    }
}
