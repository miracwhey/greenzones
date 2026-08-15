import Compression
import Foundation

/// Gzip-Auspacken ohne Fremdabhaengigkeit.
///
/// Apples `Compression` kennt kein Gzip: `COMPRESSION_ZLIB` ist ROHES Deflate
/// (RFC 1951) ohne jeden Rahmen. Der Gzip-Rahmen (RFC 1952) wird deshalb hier
/// abgeschnitten — 10 Byte Kopf plus die optionalen Felder, die die Flags
/// ankuendigen — und nur die Nutzlast an den Stream gegeben.
enum Inflate {
    enum Failure: Error, Equatable {
        case notGzip
        case truncatedHeader
        case streamFailed
    }

    /// Nutzlast-Bereich innerhalb eines Gzip-Puffers (ohne Kopf, ohne 8-Byte-Fuss).
    static func gzipPayloadRange(_ data: Data) throws -> Range<Int> {
        let base = data.startIndex
        guard data.count >= 18 else { throw Failure.truncatedHeader }
        guard data[base] == 0x1F, data[base + 1] == 0x8B else { throw Failure.notGzip }
        guard data[base + 2] == 0x08 else { throw Failure.notGzip }
        let flags = data[base + 3]
        var offset = base + 10

        func need(_ n: Int) throws {
            guard offset + n <= data.endIndex else { throw Failure.truncatedHeader }
        }

        if flags & 0x04 != 0 { // FEXTRA
            try need(2)
            let extraLength = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2
            try need(extraLength)
            offset += extraLength
        }
        if flags & 0x08 != 0 { // FNAME, nullterminiert
            while offset < data.endIndex, data[offset] != 0 { offset += 1 }
            try need(1)
            offset += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT, nullterminiert
            while offset < data.endIndex, data[offset] != 0 { offset += 1 }
            try need(1)
            offset += 1
        }
        if flags & 0x02 != 0 { // FHCRC
            try need(2)
            offset += 2
        }
        // Die letzten 8 Byte sind CRC32 + ISIZE, kein Deflate-Inhalt.
        let end = data.endIndex - 8
        guard offset < end else { throw Failure.truncatedHeader }
        return offset..<end
    }

    /// Gzip → Rohdaten. `sizeHint` beschleunigt nur die Puffer-Reservierung.
    static func gunzip(_ data: Data, sizeHint: Int = 0) throws -> Data {
        let range = try gzipPayloadRange(data)
        return try rawInflate(data[range], sizeHint: sizeHint)
    }

    /// Rohes Deflate (RFC 1951) auspacken. Streaming, weil die Zielgroesse
    /// unbekannt ist — ein geratener Faktor waere bei dichten Tiles ein stiller
    /// Datenverlust.
    static func rawInflate<D: DataProtocol>(_ payload: D, sizeHint: Int = 0) throws -> Data {
        let input = Data(payload)
        guard !input.isEmpty else { return Data() }

        let bufferSize = max(64 * 1024, min(sizeHint, 4 * 1024 * 1024))
        var output = Data()
        output.reserveCapacity(max(sizeHint, input.count * 4))

        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        var status = compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard status == COMPRESSION_STATUS_OK else { throw Failure.streamFailed }
        defer { compression_stream_destroy(streamPointer) }

        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }

        var thrown: Error?
        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            streamPointer.pointee.src_ptr = base
            streamPointer.pointee.src_size = raw.count
            streamPointer.pointee.dst_ptr = destination
            streamPointer.pointee.dst_size = bufferSize

            repeat {
                status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = bufferSize - streamPointer.pointee.dst_size
                    if produced > 0 {
                        output.append(destination, count: produced)
                        streamPointer.pointee.dst_ptr = destination
                        streamPointer.pointee.dst_size = bufferSize
                    } else if status == COMPRESSION_STATUS_OK {
                        // Kein Fortschritt trotz freiem Ziel: waere eine Endlosschleife.
                        thrown = Failure.streamFailed
                        return
                    }
                default:
                    thrown = Failure.streamFailed
                    return
                }
            } while status == COMPRESSION_STATUS_OK
        }
        if let thrown { throw thrown }
        return output
    }
}
