import Foundation

/// Wo die Bilder liegen (SPEC 4).
///
/// Eigene Originale gehoeren in `Application Support` — sie sind Bestand, den
/// niemand sonst hat. Alles Nachladbare (Thumbs, fremde Originale) liegt in
/// `Caches`: raeumt iOS dort auf, kostet das einen Netz-Abruf, keine Erinnerung.
public struct SnapFiles: Sendable {
    private let originals: URL
    private let thumbs: URL
    private let remote: URL

    /// `FileManager.default` ist nicht `Sendable`; er wird deshalb bei Bedarf
    /// geholt statt gehalten.
    private var manager: FileManager { .default }

    public init(base: URL? = nil) {
        let support = base ?? (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                            in: .userDomainMask,
                                                            appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let caches = base ?? (try? FileManager.default.url(for: .cachesDirectory,
                                                           in: .userDomainMask,
                                                           appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        originals = support.appendingPathComponent("snaps", isDirectory: true)
        thumbs = caches.appendingPathComponent("snaps/thumb", isDirectory: true)
        remote = caches.appendingPathComponent("snaps/photo", isDirectory: true)
    }

    public func originalURL(id: String) -> URL { originals.appendingPathComponent("\(id).jpg") }
    public func thumbURL(id: String) -> URL { thumbs.appendingPathComponent("\(id).jpg") }
    /// Fremdes Original — nachladbar, deshalb im Cache.
    public func remoteOriginalURL(id: String) -> URL { remote.appendingPathComponent("\(id).jpg") }

    @discardableResult
    public func writeOriginal(_ data: Data, id: String) throws -> URL {
        try write(data, to: originalURL(id: id))
    }

    @discardableResult
    public func writeThumb(_ data: Data, id: String) throws -> URL {
        try write(data, to: thumbURL(id: id))
    }

    @discardableResult
    public func writeRemoteOriginal(_ data: Data, id: String) throws -> URL {
        try write(data, to: remoteOriginalURL(id: id))
    }

    /// Liegt die Datei (noch) da? Der Cache kann jederzeit geleert worden sein.
    public func exists(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        return manager.fileExists(atPath: path)
    }

    public func delete(_ snap: Snap) {
        for url in [originalURL(id: snap.id), thumbURL(id: snap.id), remoteOriginalURL(id: snap.id)] {
            try? manager.removeItem(at: url)
        }
    }

    private func write(_ data: Data, to url: URL) throws -> URL {
        try manager.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        // Atomar: ein abgebrochener Schreibvorgang darf keine halbe Datei
        // hinterlassen, die als gueltiges Bild gilt.
        try data.write(to: url, options: .atomic)
        return url
    }
}
