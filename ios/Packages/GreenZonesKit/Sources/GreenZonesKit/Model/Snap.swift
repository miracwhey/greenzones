import CoreLocation
import Foundation

/// Wer einen Snap sehen darf (Leon-Lock aus dem Design-Gate).
///
/// `feed` ist der Default: alle Freunde. `spot` heisst „nur Freunde im Spot" —
/// gemeint sind dessen **Mitglieder**, nicht die gerade Anwesenden.
public enum SnapScope: String, Equatable, Sendable {
    case feed
    case spot
}

/// Wo ein Snap im Upload steht. Ein Snap ist ab dem Ausloesen lokal vollstaendig
/// da; die Cloud holt auf. `failed` bleibt sichtbar (Album zeigt „wartet auf
/// Upload"), damit niemand glaubt, das Bild sei weg.
public enum SnapUploadState: String, Equatable, Sendable {
    case pending
    case uploading
    case done
    case failed

    /// Steht noch etwas aus? `uploading` zaehlt dazu: ein abgebrochener Lauf
    /// (App beendet) muss beim naechsten Start wieder aufgenommen werden.
    public var isOutstanding: Bool { self == .pending || self == .uploading || self == .failed }
}

/// Ein Foto an einem Ort. Eigene wie fremde.
///
/// Der Ort steht IM Record, nicht im Bild: die Aufnahme-Position wird beim
/// Verarbeiten aus den EXIF-Daten entfernt (SPEC 10.2). Ein weitergegebenes
/// Foto verraet damit nichts, was der Empfaenger nicht ohnehin sieht.
public struct Snap: Equatable, Sendable, Identifiable {
    public var id: String
    /// `SELF_ID` fuer eigene Snaps, sonst die userRecordID des Autors.
    public var authorId: String
    public var createdAt: Date
    public var lat: Double
    public var lng: Double
    /// Lokale Spot-Id, wenn der Snap zu einem Spot gehoert.
    public var spotId: String?
    /// Zonen-Name des Spots — traegt fremde Feed-Snaps zum richtigen Album,
    /// auch wenn der Spot lokal (noch) nicht bekannt ist.
    public var spotZone: String?
    /// Name und Zeichen des Spots zum Zeitpunkt der Aufnahme. Fuer Aussenstehende
    /// ist das die einzige Beschriftung („bei 🌳 Maschsee-Ecke").
    public var spotName: String?
    public var spotEmoji: String?
    public var scope: SnapScope
    /// Zone, in der der Record liegt (`feed-…` oder `spot-…`); leer solange der
    /// Snap nur lokal existiert.
    public var zoneName: String?
    /// `recordName` in CloudKit — bei eigenen Snaps die lokale Id.
    public var recordName: String?
    public var thumbPath: String?
    public var photoPath: String?
    public var uploadState: SnapUploadState
    /// Gemeldet oder selbst ausgeblendet: bleibt in der DB, verschwindet aus
    /// Album und Karte.
    public var hidden: Bool

    public init(id: String = UUID().uuidString, authorId: String, createdAt: Date,
                lat: Double, lng: Double, spotId: String? = nil, spotZone: String? = nil,
                spotName: String? = nil, spotEmoji: String? = nil, scope: SnapScope = .feed,
                zoneName: String? = nil, recordName: String? = nil,
                thumbPath: String? = nil, photoPath: String? = nil,
                uploadState: SnapUploadState = .pending, hidden: Bool = false) {
        self.id = id
        self.authorId = authorId
        self.createdAt = createdAt
        self.lat = lat
        self.lng = lng
        self.spotId = spotId
        self.spotZone = spotZone
        self.spotName = spotName
        self.spotEmoji = spotEmoji
        self.scope = scope
        self.zoneName = zoneName
        self.recordName = recordName
        self.thumbPath = thumbPath
        self.photoPath = photoPath
        self.uploadState = uploadState
        self.hidden = hidden
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    public var isMine: Bool { authorId == SELF_ID }

    /// Ein Snap ohne Spot-Bezug steht als eigener Pin auf der Karte.
    public var isFree: Bool { spotId == nil && spotZone == nil }
}

/// Album eines Spots: eigene Spot-Snaps UND die Feed-Snaps aller Teilnehmer,
/// die an diesem Spot aufgenommen wurden (SPEC 7 „Album-Union").
///
/// Die Vereinigung laeuft ueber `spotZone`, nicht ueber `spotId`: ein fremder
/// Feed-Snap kennt nur den Zonen-Namen des Spots, nie meine lokale Id.
public func albumSnaps(_ all: [Snap], spot: Spot) -> [Snap] {
    all.filter { snap in
        guard !snap.hidden else { return false }
        if let spotId = snap.spotId, spotId == spot.id { return true }
        if let zone = snap.spotZone, let spotZone = spot.zoneName, zone == spotZone { return true }
        return false
    }
    // Neuester zuerst (Leon-Lock: Album ist ein Gedaechtnis, kein Verfall).
    .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
}

/// Snaps, die als eigener Pin auf der Karte stehen: ohne Spot-Bezug, sichtbar.
public func freeSnaps(_ all: [Snap]) -> [Snap] {
    all.filter { !$0.hidden && $0.isFree }
        .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
}
