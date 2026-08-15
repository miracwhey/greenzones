import Foundation

/// Mapbox-Vector-Tile 2.1 ohne Protobuf-Abhaengigkeit.
///
/// Gelesen wird nur, was die Legal-Status-Engine braucht: Layer-Name, `extent`
/// und die Geometrie der Features. Attribute (`tags`, `values`) werden
/// uebersprungen — die Zonen tragen keine, die den Status beeinflussen.
public enum MVTGeometryType: Int, Sendable {
    case unknown = 0
    case point = 1
    case lineString = 2
    case polygon = 3
}

/// Geometrie in KACHEL-Koordinaten, flach als `[x, y, x, y, …]` je Ring.
/// Bei Polygonen sind die Ringe durch `ClosePath` bereits geschlossen (letzter
/// Punkt == erster Punkt), genau wie im JS-Dekoder von v1.
public struct MVTFeature: Sendable {
    public let type: MVTGeometryType
    public let rings: [[Double]]
}

public struct MVTLayer: Sendable {
    public let name: String
    public let extent: Int
    public let features: [MVTFeature]
}

public enum MVTError: Error, Equatable {
    case truncated
    case unknownGeometryCommand(Int)
}

public enum MVTDecoder {
    /// `only` filtert Layer schon vor dem Feature-Parsen.
    public static func decode(_ data: Data, only: Set<String>? = nil) throws -> [MVTLayer] {
        var reader = ProtobufReader(data)
        var layers: [MVTLayer] = []
        while try reader.hasMore() {
            let (field, wire) = try reader.readTag()
            // Tile.layers = 3
            if field == 3, wire == 2 {
                let slice = try reader.readLengthDelimited()
                if let layer = try decodeLayer(slice, only: only) {
                    layers.append(layer)
                }
            } else {
                try reader.skip(wire)
            }
        }
        return layers
    }

    static func decodeLayer(_ data: Data, only: Set<String>?) throws -> MVTLayer? {
        var reader = ProtobufReader(data)
        var name = ""
        var extent = 4096
        var featureSlices: [Data] = []

        while try reader.hasMore() {
            let (field, wire) = try reader.readTag()
            switch (field, wire) {
            case (1, 2): // name
                name = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            case (2, 2): // features
                featureSlices.append(try reader.readLengthDelimited())
            case (5, 0): // extent
                extent = Int(try reader.readVarint())
            default:
                try reader.skip(wire)
            }
        }
        if let only, !only.contains(name) { return nil }

        var features: [MVTFeature] = []
        features.reserveCapacity(featureSlices.count)
        for slice in featureSlices {
            features.append(try decodeFeature(slice))
        }
        return MVTLayer(name: name, extent: extent, features: features)
    }

    static func decodeFeature(_ data: Data) throws -> MVTFeature {
        var reader = ProtobufReader(data)
        var type = MVTGeometryType.unknown
        var geometry = Data()

        while try reader.hasMore() {
            let (field, wire) = try reader.readTag()
            switch (field, wire) {
            case (3, 0): // type
                type = MVTGeometryType(rawValue: Int(try reader.readVarint())) ?? .unknown
            case (4, 2): // geometry (packed)
                geometry = try reader.readLengthDelimited()
            default:
                try reader.skip(wire)
            }
        }
        return MVTFeature(type: type, rings: try decodeGeometry(geometry))
    }

    /// Kommando-Strom MoveTo(1)/LineTo(2)/ClosePath(7), Deltas zickzack-kodiert.
    static func decodeGeometry(_ data: Data) throws -> [[Double]] {
        var reader = ProtobufReader(data)
        var command = 1
        var remaining = 0
        var x = 0.0
        var y = 0.0
        var lines: [[Double]] = []
        var line: [Double]?

        while try reader.hasMore() {
            if remaining <= 0 {
                let commandInteger = Int(try reader.readVarint())
                command = commandInteger & 0x7
                remaining = commandInteger >> 3
                if remaining <= 0 { continue }
            }
            remaining -= 1

            switch command {
            case 1, 2:
                x += Double(try reader.readSignedVarint())
                y += Double(try reader.readSignedVarint())
                if command == 1 {
                    if let line { lines.append(line) }
                    line = []
                }
                line?.append(x)
                line?.append(y)
            case 7:
                // Wie `@mapbox/vector-tile`: der Ring bekommt seinen Startpunkt
                // als Endpunkt — die Kanten-Distanz in geo.ts zaehlt darauf.
                if line != nil, line!.count >= 2 {
                    line!.append(line![0])
                    line!.append(line![1])
                }
            default:
                throw MVTError.unknownGeometryCommand(command)
            }
        }
        if let line { lines.append(line) }
        return lines
    }

    // MARK: - Polygone in Weltkoordinaten

    /// Flaeche eines Rings mit Vorzeichen (Kachel-Koordinaten, y nach unten).
    /// Positiv = Aussenring, negativ = Loch — die Konvention von `classifyRings`.
    static func signedArea(_ ring: [Double]) -> Double {
        let count = ring.count / 2
        guard count > 1 else { return 0 }
        var sum = 0.0
        var j = count - 1
        for i in 0..<count {
            let p1x = ring[2 * i], p1y = ring[2 * i + 1]
            let p2x = ring[2 * j], p2y = ring[2 * j + 1]
            sum += (p2x - p1x) * (p1y + p2y)
            j = i
        }
        return sum
    }

    /// Port von `classifyRings`: die flache Ring-Liste eines Features in
    /// Polygone gruppieren. Der erste Ring mit Flaeche gibt die Aussen-Orientierung
    /// vor, gleich orientierte Ringe beginnen ein neues Polygon, gegenlaeufige
    /// sind Loecher des laufenden.
    static func classifyRings(_ rings: [[Double]]) -> [[[Double]]] {
        if rings.count <= 1 { return [rings] }
        var polygons: [[[Double]]] = []
        var polygon: [[Double]]?
        var ccw: Bool?

        for ring in rings {
            let area = signedArea(ring)
            if area == 0 { continue }
            if ccw == nil { ccw = area < 0 }
            if ccw == (area < 0) {
                if let polygon { polygons.append(polygon) }
                polygon = [ring]
            } else if polygon != nil {
                polygon?.append(ring)
            }
        }
        if let polygon { polygons.append(polygon) }
        return polygons
    }

    /// Kachel-Koordinaten → lng/lat, exakt die Rechnung aus
    /// `VectorTileFeature.toGeoJSON` (Web-Mercator rueckwaerts).
    public static func polygons(_ feature: MVTFeature,
                                x: Int, y: Int, z: Int, extent: Int) -> [GZPolygon] {
        guard feature.type == .polygon else { return [] }
        let size = Double(extent) * pow(2, Double(z))
        let x0 = Double(extent) * Double(x)
        let y0 = Double(extent) * Double(y)

        return classifyRings(feature.rings).map { rings in
            rings.map { ring -> GZRing in
                var out = GZRing()
                out.reserveCapacity(ring.count)
                var index = 0
                while index < ring.count {
                    let px = ring[index]
                    let py = ring[index + 1]
                    let y2 = 180 - (py + y0) * 360 / size
                    out.append((px + x0) * 360 / size - 180)
                    out.append(360 / Double.pi * atan(exp(y2 * Double.pi / 180)) - 90)
                    index += 2
                }
                return out
            }
        }
    }
}

/// Minimaler Protobuf-Leser (nur die Wire-Typen, die MVT benutzt).
struct ProtobufReader {
    private let data: Data
    private var position: Int

    init(_ data: Data) {
        self.data = data
        position = data.startIndex
    }

    func hasMore() throws -> Bool { position < data.endIndex }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while position < data.endIndex {
            let byte = data[position]
            position += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw MVTError.truncated }
        }
        throw MVTError.truncated
    }

    /// Zickzack: 0, -1, 1, -2 … → 0, 1, 2, 3 …
    mutating func readSignedVarint() throws -> Int64 {
        let raw = try readVarint()
        return Int64(bitPattern: (raw >> 1)) ^ -Int64(bitPattern: raw & 1)
    }

    mutating func readTag() throws -> (field: Int, wire: Int) {
        let value = try readVarint()
        return (Int(value >> 3), Int(value & 0x7))
    }

    mutating func readLengthDelimited() throws -> Data {
        let length = Int(try readVarint())
        guard length >= 0, position + length <= data.endIndex else { throw MVTError.truncated }
        let slice = data[position..<(position + length)]
        position += length
        // `Data(slice)` normiert den Index-Ursprung auf 0 — Sub-Reader duerfen
        // sonst nicht bei `startIndex` beginnen.
        return Data(slice)
    }

    mutating func skip(_ wire: Int) throws {
        switch wire {
        case 0: _ = try readVarint()
        case 1: try advance(8)
        case 2: _ = try readLengthDelimited()
        case 5: try advance(4)
        default: throw MVTError.truncated
        }
    }

    private mutating func advance(_ count: Int) throws {
        guard position + count <= data.endIndex else { throw MVTError.truncated }
        position += count
    }
}
