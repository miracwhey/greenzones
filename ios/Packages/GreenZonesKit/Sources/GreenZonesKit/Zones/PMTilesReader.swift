import Foundation

/// Eigener Leser fuer PMTiles v3 (Spec:
/// https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md).
///
/// Warum eigen statt der Karten-Bibliothek: die Legal-Status-Engine muss auch
/// ausserhalb des Viewports und ohne Renderer antworten (SPEC E6) — sie liest
/// dieselbe Datei, aber selbst.
public struct PMTilesHeader: Equatable, Sendable {
    public let rootDirectoryOffset: UInt64
    public let rootDirectoryLength: UInt64
    public let metadataOffset: UInt64
    public let metadataLength: UInt64
    public let leafDirectoryOffset: UInt64
    public let leafDirectoryLength: UInt64
    public let tileDataOffset: UInt64
    public let tileDataLength: UInt64
    public let addressedTilesCount: UInt64
    public let tileEntriesCount: UInt64
    public let tileContentsCount: UInt64
    public let clustered: Bool
    public let internalCompression: PMTilesCompression
    public let tileCompression: PMTilesCompression
    public let tileType: UInt8
    public let minZoom: UInt8
    public let maxZoom: UInt8
    public let minLon: Double
    public let minLat: Double
    public let maxLon: Double
    public let maxLat: Double

    public static let byteLength = 127
}

public enum PMTilesCompression: UInt8, Sendable {
    case unknown = 0
    case none = 1
    case gzip = 2
    case brotli = 3
    case zstd = 4
}

public enum PMTilesError: Error, Equatable {
    case badMagic
    case unsupportedVersion(UInt8)
    case truncated
    case unsupportedCompression(UInt8)
    /// Ein Leaf-Verweis zeigt wieder auf einen Leaf-Verweis ohne Ende.
    case directoryLoop
}

struct PMTilesEntry {
    var tileID: UInt64
    var offset: UInt64
    var length: UInt32
    var runLength: UInt32
}

/// Liest Kacheln aus einem PMTiles-Archiv im Dateisystem.
///
/// `FileHandle` statt `Data(contentsOf:)`: die Datei ist 61,7 MB, sie soll nicht
/// im Speicher liegen. Die Wurzel-Directory (177 Byte) wird einmal geladen,
/// Leaf-Directories nach Bedarf und dann behalten (das Archiv hat 228 KB davon).
public final class PMTilesArchive {
    public let header: PMTilesHeader
    private let handle: FileHandle
    private let rootEntries: [PMTilesEntry]
    private var leafCache: [UInt64: [PMTilesEntry]] = [:]

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let headerData = try PMTilesArchive.read(handle, offset: 0, length: PMTilesHeader.byteLength)
        header = try PMTilesArchive.parseHeader(headerData)
        let rootRaw = try PMTilesArchive.read(handle,
                                              offset: Int(header.rootDirectoryOffset),
                                              length: Int(header.rootDirectoryLength))
        rootEntries = try PMTilesArchive.parseDirectory(
            PMTilesArchive.decompress(rootRaw, using: header.internalCompression))
    }

    deinit { try? handle.close() }

    // MARK: - Kachel-Zugriff

    /// Rohe (bereits ausgepackte) Kachel-Nutzlast, `nil` wenn die Kachel fehlt.
    public func tile(z: Int, x: Int, y: Int) throws -> Data? {
        guard let tileID = PMTilesArchive.zxyToTileID(z: z, x: x, y: y) else { return nil }
        var entries = rootEntries
        // Die Spec erlaubt Root → Leaf → Leaf; drei Runden sind bei maxZoom 14
        // grosszuegig und beenden jede Schleife.
        for _ in 0..<4 {
            guard let entry = PMTilesArchive.findTile(entries, tileID) else { return nil }
            if entry.runLength == 0 {
                let key = entry.offset
                if let cached = leafCache[key] {
                    entries = cached
                } else {
                    let raw = try PMTilesArchive.read(
                        handle,
                        offset: Int(header.leafDirectoryOffset + entry.offset),
                        length: Int(entry.length))
                    let parsed = try PMTilesArchive.parseDirectory(
                        PMTilesArchive.decompress(raw, using: header.internalCompression))
                    leafCache[key] = parsed
                    entries = parsed
                }
                continue
            }
            let raw = try PMTilesArchive.read(handle,
                                              offset: Int(header.tileDataOffset + entry.offset),
                                              length: Int(entry.length))
            return try PMTilesArchive.decompress(raw, using: header.tileCompression)
        }
        throw PMTilesError.directoryLoop
    }

    // MARK: - Kopf

    static func parseHeader(_ data: Data) throws -> PMTilesHeader {
        guard data.count >= PMTilesHeader.byteLength else { throw PMTilesError.truncated }
        let magic = data.prefix(7)
        guard magic.elementsEqual("PMTiles".utf8) else { throw PMTilesError.badMagic }
        let version = data[data.startIndex + 7]
        guard version == 3 else { throw PMTilesError.unsupportedVersion(version) }

        func u64(_ at: Int) -> UInt64 {
            var value: UInt64 = 0
            for i in 0..<8 {
                value |= UInt64(data[data.startIndex + at + i]) << (8 * i)
            }
            return value
        }
        func i32(_ at: Int) -> Int32 {
            var value: UInt32 = 0
            for i in 0..<4 {
                value |= UInt32(data[data.startIndex + at + i]) << (8 * i)
            }
            return Int32(bitPattern: value)
        }
        func compression(_ at: Int) throws -> PMTilesCompression {
            let raw = data[data.startIndex + at]
            guard let value = PMTilesCompression(rawValue: raw) else {
                throw PMTilesError.unsupportedCompression(raw)
            }
            return value
        }

        return PMTilesHeader(
            rootDirectoryOffset: u64(8),
            rootDirectoryLength: u64(16),
            metadataOffset: u64(24),
            metadataLength: u64(32),
            leafDirectoryOffset: u64(40),
            leafDirectoryLength: u64(48),
            tileDataOffset: u64(56),
            tileDataLength: u64(64),
            addressedTilesCount: u64(72),
            tileEntriesCount: u64(80),
            tileContentsCount: u64(88),
            clustered: data[data.startIndex + 96] == 1,
            internalCompression: try compression(97),
            tileCompression: try compression(98),
            tileType: data[data.startIndex + 99],
            minZoom: data[data.startIndex + 100],
            maxZoom: data[data.startIndex + 101],
            minLon: Double(i32(102)) / 1e7,
            minLat: Double(i32(106)) / 1e7,
            maxLon: Double(i32(110)) / 1e7,
            maxLat: Double(i32(114)) / 1e7)
    }

    // MARK: - Directory

    /// Directory-Eintraege liegen spaltenweise als Varints: erst alle Kachel-IDs
    /// (Delta), dann alle Lauflaengen, dann alle Laengen, dann alle Offsets
    /// (`0` = luecklos hinter dem Vorgaenger).
    static func parseDirectory(_ data: Data) throws -> [PMTilesEntry] {
        var reader = VarintReader(data)
        let count = Int(try reader.readVarint())
        guard count >= 0 else { throw PMTilesError.truncated }
        var entries = [PMTilesEntry](repeating: PMTilesEntry(tileID: 0, offset: 0, length: 0, runLength: 0),
                                     count: count)

        var lastID: UInt64 = 0
        for i in 0..<count {
            lastID &+= try reader.readVarint()
            entries[i].tileID = lastID
        }
        for i in 0..<count {
            entries[i].runLength = UInt32(truncatingIfNeeded: try reader.readVarint())
        }
        for i in 0..<count {
            entries[i].length = UInt32(truncatingIfNeeded: try reader.readVarint())
        }
        for i in 0..<count {
            let value = try reader.readVarint()
            if value == 0 && i > 0 {
                entries[i].offset = entries[i - 1].offset + UInt64(entries[i - 1].length)
            } else {
                entries[i].offset = value - 1
            }
        }
        return entries
    }

    /// Binaere Suche mit Lauflaengen: ein Eintrag deckt `runLength` fortlaufende
    /// Kachel-IDs ab (identischer Inhalt), `runLength == 0` ist ein Leaf-Verweis.
    static func findTile(_ entries: [PMTilesEntry], _ tileID: UInt64) -> PMTilesEntry? {
        var low = 0
        var high = entries.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if tileID > entries[mid].tileID {
                low = mid + 1
            } else if tileID < entries[mid].tileID {
                high = mid - 1
            } else {
                return entries[mid]
            }
        }
        guard high >= 0 else { return nil }
        let candidate = entries[high]
        if candidate.runLength == 0 { return candidate }
        if tileID - candidate.tileID < UInt64(candidate.runLength) { return candidate }
        return nil
    }

    // MARK: - Hilbert

    /// z/x/y → Kachel-ID auf der Hilbert-Kurve (Spec v3). `nil` ausserhalb des
    /// Zoom-Gitters — das ist der Normalfall am Rand des 3×3-Fensters.
    public static func zxyToTileID(z: Int, x: Int, y: Int) -> UInt64? {
        guard z >= 0, z <= 26, x >= 0, y >= 0 else { return nil }
        let n = 1 << z
        guard x < n, y < n else { return nil }
        // (4^z - 1) / 3 = Anzahl aller Kacheln unterhalb von z.
        let acc = ((UInt64(1) << (2 * UInt64(z))) - 1) / 3
        var rx = 0
        var ry = 0
        var d: UInt64 = 0
        var xx = x
        var yy = y
        var s = n / 2
        while s > 0 {
            rx = (xx & s) > 0 ? 1 : 0
            ry = (yy & s) > 0 ? 1 : 0
            d &+= UInt64(s) * UInt64(s) * UInt64((3 * rx) ^ ry)
            if ry == 0 {
                if rx == 1 {
                    xx = s - 1 - xx
                    yy = s - 1 - yy
                }
                let t = xx
                xx = yy
                yy = t
            }
            s /= 2
        }
        return acc &+ d
    }

    // MARK: - Rohzugriff

    static func read(_ handle: FileHandle, offset: Int, length: Int) throws -> Data {
        guard length > 0 else { return Data() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: length), data.count == length else {
            throw PMTilesError.truncated
        }
        return data
    }

    static func decompress(_ data: Data, using compression: PMTilesCompression) throws -> Data {
        switch compression {
        case .none:
            return data
        case .gzip:
            return try Inflate.gunzip(data)
        case .unknown, .brotli, .zstd:
            throw PMTilesError.unsupportedCompression(compression.rawValue)
        }
    }
}

/// Minimaler Varint-Leser (LEB128, wie Protobuf) fuer Directories.
struct VarintReader {
    private let data: Data
    private(set) var position: Int

    init(_ data: Data) {
        self.data = data
        position = data.startIndex
    }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while position < data.endIndex {
            let byte = data[position]
            position += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw PMTilesError.truncated }
        }
        throw PMTilesError.truncated
    }
}
