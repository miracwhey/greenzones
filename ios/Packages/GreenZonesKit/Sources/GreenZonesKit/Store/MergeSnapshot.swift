import Foundation

/// Der lokale Bestand als Ganzes — Ein- und Ausgabe des Merges.
public struct LocalState: Equatable, Sendable {
    public var spots: [Spot]
    public var friends: [Friend]
    public var invitations: [Invitation]

    public init(spots: [Spot] = [], friends: [Friend] = [], invitations: [Invitation] = []) {
        self.spots = spots
        self.friends = friends
        self.invitations = invitations
    }
}

/// Merge des Cloud-Snapshots in den lokalen Bestand. Port von `mergeSnapshot()`
/// aus `client/src/lib/spots/sync.ts` — pur und ohne Seiteneffekt, damit
/// Idempotenz pruefbar ist.
///
/// Drei Regeln tragen alles Weitere:
///  1. Wahrheit: Fuer geteilte Zonen gewinnt der Snapshot. Rein lokale Spots
///     (ohne `zoneName`) und ihre Einladungen bleiben unberuehrt — sie sind
///     Schublade A und haben in der Cloud kein Gegenstueck.
///  2. Idempotenz: Derselbe Snapshot zweimal ergibt exakt dieselben Listen. Der
///     Merge sortiert deshalb alles, was aus der Cloud in beliebiger Reihenfolge
///     kommen kann.
///  3. Zwei bewusste Grenzen der Regel „Cloud gewinnt":
///     - Ein EIGENER geteilter Spot verschwindet nicht, nur weil er in einem
///       Snapshot fehlt (CloudKit-Abfragen laufen der Anlage hinterher).
///       Entfernt wird er ausschliesslich durch `SyncCoordinator.removeSpot`.
///     - Einladungen werden nie geloescht, sondern abgesagt (`cancelled`). Eine
///       im Snapshot fehlende Einladung heisst „noch nicht sichtbar", nicht
///       „weg". Sie verschwindet nur mit ihrem Spot.
public func mergeSnapshot(_ snapshot: CloudSnapshot, current: LocalState) -> LocalState {
    let mapSelf: (String) -> String = { id in
        !id.isEmpty && id == snapshot.userID ? SELF_ID : id
    }

    let friends: [Friend] = snapshot.friends
        .map { cloud in
            Friend(id: cloud.userID,
                   name: cloud.name,
                   emoji: cloud.emoji,
                   color: friendColor(cloud.userID),
                   friendshipZone: cloud.friendshipZone)
        }
        .sorted { a, b in
            a.name == b.name ? a.id < b.id : a.name < b.name
        }

    var open = Dictionary(uniqueKeysWithValues: snapshot.spots.map { ($0.zoneName, $0) })
    var spots: [Spot] = []
    for spot in current.spots {
        guard let zone = spot.zoneName else {
            spots.append(spot)
            continue
        }
        if let cloud = open[zone] {
            spots.append(fromCloudSpot(cloud, mapSelf: mapSelf, local: spot))
            open[zone] = nil
        } else if spot.ownerId == SELF_ID {
            spots.append(spot)
        }
    }
    let arrived = open.values.sorted { a, b in
        a.createdAt == b.createdAt ? a.zoneName < b.zoneName : a.createdAt < b.createdAt
    }
    for cloud in arrived {
        spots.append(fromCloudSpot(cloud, mapSelf: mapSelf, local: nil))
    }

    var spotIdByZone: [String: String] = [:]
    for spot in spots { if let zone = spot.zoneName { spotIdByZone[zone] = spot.id } }
    let knownSpotIds = Set(spots.map(\.id))

    var openInvites: [String: CloudInvitation] = [:]
    for invitation in snapshot.invitations where spotIdByZone[invitation.spotZone] != nil {
        openInvites[invitation.id] = invitation
    }
    var invitations: [Invitation] = []
    for invitation in current.invitations {
        guard knownSpotIds.contains(invitation.spotId) else { continue }
        guard let cloud = openInvites[invitation.id] else {
            invitations.append(invitation)
            continue
        }
        invitations.append(fromCloudInvitation(cloud, spotId: invitation.spotId,
                                               mapSelf: mapSelf, local: invitation))
        openInvites[invitation.id] = nil
    }
    let arrivedInvites = openInvites.values.sorted { a, b in
        a.createdAt == b.createdAt ? a.id < b.id : a.createdAt < b.createdAt
    }
    for cloud in arrivedInvites {
        guard let spotId = spotIdByZone[cloud.spotZone] else { continue }
        invitations.append(fromCloudInvitation(cloud, spotId: spotId, mapSelf: mapSelf, local: nil))
    }

    return LocalState(spots: spots, friends: friends, invitations: invitations)
}

private func fromCloudSpot(_ cloud: CloudSpot, mapSelf: (String) -> String,
                           local: Spot?) -> Spot {
    Spot(id: local?.id ?? localSpotId(cloud.zoneName),
         name: cloud.name,
         emoji: cloud.emoji,
         lng: cloud.lng,
         lat: cloud.lat,
         createdAt: cloud.createdAt,
         zoneName: cloud.zoneName,
         ownerId: cloud.isMine ? SELF_ID : mapSelf(cloud.ownerUserID),
         participantIds: cloud.participantUserIDs.map(mapSelf)
             .filter { $0 != SELF_ID }
             .sorted(),
         // Leere Share-URL ist „keine" — sonst stuende bei Fremd-Spots ein
         // leerer String, wo v1 gar nichts hat, und der Vergleich schluege aus.
         shareURL: cloud.shareURL.isEmpty ? nil : cloud.shareURL,
         // Der Snapshot IST die Cloud-Wahrheit: was dort steht, liegt nicht mehr
         // in der Outbox.
         sharePending: false)
}

/// Antworten sind Upserts pro Person und werden nie geloescht: Cloud gewinnt,
/// lokale Extras bleiben.
private func mergeReplies(local: [Reply], cloud: [Reply]) -> [Reply] {
    var byParticipant: [String: Reply] = [:]
    var order: [String] = []
    for reply in local where byParticipant[reply.participantId] == nil {
        byParticipant[reply.participantId] = reply
        order.append(reply.participantId)
    }
    for reply in cloud {
        if byParticipant[reply.participantId] == nil { order.append(reply.participantId) }
        byParticipant[reply.participantId] = reply
    }
    return order.compactMap { byParticipant[$0] }.sorted { $0.participantId < $1.participantId }
}

private func fromCloudInvitation(_ cloud: CloudInvitation, spotId: String,
                                 mapSelf: (String) -> String,
                                 local: Invitation?) -> Invitation {
    Invitation(id: cloud.id,
               spotId: spotId,
               hostId: mapSelf(cloud.hostUserID),
               time: cloud.time,
               createdAt: cloud.createdAt,
               cancelled: cloud.cancelled,
               replies: mergeReplies(
                   local: local?.replies ?? [],
                   cloud: cloud.replies.map {
                       Reply(participantId: mapSelf($0.participantUserID),
                             status: $0.status,
                             arrivalTime: $0.arrivalTime)
                   }))
}
