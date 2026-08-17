import Foundation

/// Snaps aus dem Vollabzug in den lokalen Bestand legen.
///
/// Eigener Merge statt Teil von `mergeSnapshot`: Snaps haben eine Eigenschaft,
/// die Spots und Einladungen nicht haben — sie tragen Dateien. Ein Merge, der
/// eine Zeile ersetzt, wuerde ein geladenes Bild verlieren.
///
/// Drei Regeln:
///  1. **Fremde Snaps folgen der Cloud.** Was dort verschwunden ist (geloescht
///     oder Zugang entzogen), verschwindet auch hier — samt Dateien.
///  2. **Eigene Snaps folgen dem Geraet.** Ein eigener Snap, der im Snapshot
///     fehlt, ist nicht weg, sondern noch nicht hochgeladen (Outbox). Er
///     verschwindet nur durch bewusstes Loeschen.
///  3. **Lokale Entscheidungen ueberleben.** Ausblenden (`hidden`) und die
///     Dateipfade bleiben — beides kennt die Cloud nicht.
public struct SnapMerge: Equatable, Sendable {
    /// Anzulegen oder zu aktualisieren.
    public var upserts: [Snap]
    /// Ids, die aus dem Bestand fallen (nur fremde).
    public var removals: [String]

    public var isEmpty: Bool { upserts.isEmpty && removals.isEmpty }
}

public func mergeSnaps(_ cloud: [CloudSnap], local: [Snap], myUserID: String,
                       spotIdForZone: (String) -> String?) -> SnapMerge {
    let existing = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var upserts: [Snap] = []
    var seen = Set<String>()

    for entry in cloud {
        seen.insert(entry.id)
        let mine = entry.authorUserID == myUserID
        // Der eigene Snap ist lokal die Wahrheit: er traegt Dateien, Zustand und
        // die Zuordnung, die dieses Geraet gesetzt hat. Aus der Cloud kommt nur
        // die Bestaetigung, dass er angekommen ist.
        if mine, let local = existing[entry.id] {
            var updated = local
            updated.zoneName = entry.zoneName
            updated.recordName = entry.id
            updated.uploadState = .done
            if updated != local { upserts.append(updated) }
            continue
        }

        let spotZone = entry.inSpotZone ? entry.zoneName : entry.spotZone
        var snap = Snap(id: entry.id,
                        authorId: mine ? SELF_ID : entry.authorUserID,
                        createdAt: entry.createdAt,
                        lat: entry.lat, lng: entry.lng,
                        spotId: spotZone.flatMap(spotIdForZone),
                        spotZone: spotZone,
                        spotName: entry.spotName,
                        spotEmoji: entry.spotEmoji,
                        scope: entry.inSpotZone ? .spot : .feed,
                        zoneName: entry.zoneName,
                        recordName: entry.id,
                        uploadState: .done)
        // Was das Geraet schon weiss, bleibt: Bilder und Ausblendung.
        if let local = existing[entry.id] {
            snap.thumbPath = local.thumbPath
            snap.photoPath = local.photoPath
            snap.hidden = local.hidden
            if snap == local { continue }
        }
        upserts.append(snap)
    }

    let removals = local
        .filter { !$0.isMine && !seen.contains($0.id) }
        .map(\.id)

    return SnapMerge(upserts: upserts, removals: removals)
}
