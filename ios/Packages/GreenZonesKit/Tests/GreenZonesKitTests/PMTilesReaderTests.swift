import CoreLocation
import Foundation
import Testing
@testable import GreenZonesKit

@Suite("PMTilesReader — v3 gegen die echte zones.pmtiles")
struct PMTilesReaderTests {
    @Test("Hilbert-Kachel-IDs entsprechen der Spec")
    func tileIDs() {
        #expect(PMTilesArchive.zxyToTileID(z: 0, x: 0, y: 0) == 0)
        #expect(PMTilesArchive.zxyToTileID(z: 1, x: 0, y: 0) == 1)
        #expect(PMTilesArchive.zxyToTileID(z: 1, x: 0, y: 1) == 2)
        #expect(PMTilesArchive.zxyToTileID(z: 1, x: 1, y: 1) == 3)
        #expect(PMTilesArchive.zxyToTileID(z: 1, x: 1, y: 0) == 4)
        #expect(PMTilesArchive.zxyToTileID(z: 2, x: 0, y: 0) == 5)
        // Ausserhalb des Gitters — im 3×3-Fenster am Rand der Normalfall.
        #expect(PMTilesArchive.zxyToTileID(z: 1, x: 2, y: 0) == nil)
        #expect(PMTilesArchive.zxyToTileID(z: 1, x: -1, y: 0) == nil)
    }

    @Test("Directory-Eintraege: Delta-IDs und luecklose Offsets")
    func directoryParsing() throws {
        // 3 Eintraege: IDs 5, 6, 9 · Lauflaengen 1,1,0 · Laengen 10,20,30
        // · Offsets 0(→ explizit 0), 0(→ luecklos), 100
        var bytes: [UInt8] = []
        func varint(_ value: UInt64) {
            var v = value
            repeat {
                var byte = UInt8(v & 0x7F)
                v >>= 7
                if v != 0 { byte |= 0x80 }
                bytes.append(byte)
            } while v != 0
        }
        varint(3)
        for delta in [5, 1, 3] { varint(UInt64(delta)) }
        for run in [1, 1, 0] { varint(UInt64(run)) }
        for length in [10, 20, 30] { varint(UInt64(length)) }
        varint(1)   // Offset 0 (Wert-1)
        varint(0)   // luecklos: 0 + 10
        varint(101) // Offset 100

        let entries = try PMTilesArchive.parseDirectory(Data(bytes))
        #expect(entries.count == 3)
        #expect(entries.map(\.tileID) == [5, 6, 9])
        #expect(entries.map(\.offset) == [0, 10, 100])
        #expect(entries.map(\.length) == [10, 20, 30])
        #expect(entries.map(\.runLength) == [1, 1, 0])
    }

    @Test("findTile: exakter Treffer, Lauflaenge, Fehlschlag")
    func lookup() throws {
        let entries = [
            PMTilesEntry(tileID: 10, offset: 0, length: 5, runLength: 3),
            PMTilesEntry(tileID: 20, offset: 5, length: 5, runLength: 1),
        ]
        #expect(PMTilesArchive.findTile(entries, 10)?.tileID == 10)
        #expect(PMTilesArchive.findTile(entries, 12)?.tileID == 10)  // in der Lauflaenge
        #expect(PMTilesArchive.findTile(entries, 13) == nil)         // hinter der Lauflaenge
        #expect(PMTilesArchive.findTile(entries, 20)?.tileID == 20)
        #expect(PMTilesArchive.findTile(entries, 9) == nil)
        #expect(PMTilesArchive.findTile(entries, 99) == nil)
    }

    @Test("Gzip-Rahmen wird korrekt abgeschnitten")
    func gzipRoundtrip() throws {
        // Von `gzip` erzeugter Rahmen mit FNAME-Flag ist der haeufigste Fall;
        // hier reicht der Minimal-Rahmen ohne optionale Felder.
        let payload = Data("Zonen sind Flaechen, keine Meinungen.".utf8)
        let gz = try Self.gzip(payload)
        #expect(try Inflate.gunzip(gz) == payload)
        #expect(throws: Inflate.Failure.notGzip) {
            _ = try Inflate.gunzip(Data(repeating: 0x41, count: 32))
        }
    }

    @Test("Kopf der echten Datei: Zoom 6–14, MVT, gzip, Bundesgebiet")
    func realHeader() throws {
        let archive = try PMTilesArchive(url: TestPaths.zonesPMTiles)
        let header = archive.header
        #expect(header.minZoom == 6)
        #expect(header.maxZoom == 14)
        #expect(header.tileType == 1)                     // MVT
        #expect(header.internalCompression == .gzip)
        #expect(header.tileCompression == .gzip)
        #expect(header.clustered)
        #expect(header.tileEntriesCount > 100_000)
        // Bounding-Box Deutschland.
        #expect(header.minLon > 5 && header.minLon < 7)
        #expect(header.maxLon > 14 && header.maxLon < 16)
        #expect(header.minLat > 46 && header.minLat < 48)
        #expect(header.maxLat > 54 && header.maxLat < 56)
    }

    @Test("Kachel an Kroepcke liefert entpackte ban/time-Layer")
    func realTile() throws {
        let archive = try PMTilesArchive(url: TestPaths.zonesPMTiles)
        let point = CLLocationCoordinate2D(latitude: 52.3745, longitude: 9.7386)
        let tile = ZoneEngine.lngLatToTile(point, z: 14)
        let raw = try #require(try archive.tile(z: 14, x: tile.x, y: tile.y))
        #expect(raw.count > 100)

        let layers = try MVTDecoder.decode(raw, only: ["ban", "time"])
        #expect(!layers.isEmpty)
        let names = Set(layers.map(\.name))
        #expect(names.isSubset(of: ["ban", "time"]))
        let polygonCount = layers
            .flatMap(\.features)
            .filter { $0.type == .polygon }
            .count
        #expect(polygonCount > 0)
    }

    @Test("Kachel weit ausserhalb der Daten ist nil, kein Fehler")
    func missingTile() throws {
        let archive = try PMTilesArchive(url: TestPaths.zonesPMTiles)
        // Mitten im Pazifik.
        let point = CLLocationCoordinate2D(latitude: 0, longitude: -150)
        let tile = ZoneEngine.lngLatToTile(point, z: 14)
        #expect(try archive.tile(z: 14, x: tile.x, y: tile.y) == nil)
    }

    // MARK: - Hilfe

    /// Minimaler Gzip-Rahmen um rohes Deflate (nur fuer den Roundtrip-Test).
    private static func gzip(_ data: Data) throws -> Data {
        let deflated = try rawDeflate(data)
        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
        out.append(deflated)
        var crc = crc32(data).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }

    private static func rawDeflate(_ data: Data) throws -> Data {
        // Ohne Kompressor waere der Test von der Umgebung abhaengig — ein
        // „stored"-Deflate-Block ist ohne Bibliothek exakt konstruierbar.
        var out = Data()
        var offset = 0
        while offset < data.count {
            let chunk = min(65535, data.count - offset)
            let final: UInt8 = (offset + chunk >= data.count) ? 1 : 0
            out.append(final)                                   // BFINAL, BTYPE=00
            let length = UInt16(chunk)
            out.append(UInt8(length & 0xFF))
            out.append(UInt8(length >> 8))
            out.append(UInt8(~length & 0xFF))
            out.append(UInt8((~length >> 8) & 0xFF))
            out.append(data.subdata(in: offset..<(offset + chunk)))
            offset += chunk
        }
        return out
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
