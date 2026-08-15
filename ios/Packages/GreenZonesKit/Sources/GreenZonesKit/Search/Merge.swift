import Foundation

/// Zusammenfuehrung der beiden Quellen. Port von `client/src/lib/search/merge.ts`.
///
/// Die Sektionen bleiben getrennt (Offline zuerst) — hier wird nur die
/// Online-Liste um das bereinigt, was der Offline-Index schon zeigt.
public enum Merge {
    /// Gleicher Name + weniger als das = derselbe Ort.
    public static let dedupeDistanceM: Double = 150

    static func sameSpot(_ a: SearchResult, _ b: SearchResult) -> Bool {
        guard Normalize.apply(a.name) == Normalize.apply(b.name) else { return false }
        return Geo.distanceM(a.coordinate, b.coordinate) < dedupeDistanceM
    }

    /// Online-Treffer, die kein Offline-Treffer bereits abdeckt.
    public static func dedupeAgainstOffline(_ offline: [SearchResult],
                                            _ online: [SearchResult]) -> [SearchResult] {
        guard !offline.isEmpty else { return online }
        return online.filter { candidate in
            !offline.contains { sameSpot($0, candidate) }
        }
    }
}
