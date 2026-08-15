import CoreLocation
import GreenZonesKit
import SwiftUI

/// Genau EIN offenes Sheet — parallele Booleans koennten sich widersprechen
/// (v1 `SheetState`).
enum SheetRoute: Equatable, Identifiable {
    case newspot
    /// „Auf Karte wählen": kein Sheet, die Karte gehoert dem Nutzer.
    case pick
    case detail(spotId: String)
    case invite(spotId: String)
    /// Freundesliste; `intent` oeffnet direkt den Profil-Schritt (Absprung aus
    /// dem Spot-Detail ohne Freunde, Debug-Route `profile`).
    case friends(intent: ProfileIntent?)
    /// Profil nach einem Beitritt — kommt vom Zustand, nicht von einem Tap.
    case profilePrompt

    var id: String {
        switch self {
        case .newspot: return "newspot"
        case .pick: return "pick"
        case .detail(let id): return "detail-\(id)"
        case .invite(let id): return "invite-\(id)"
        case .friends(let intent): return "friends-\(intent?.key ?? "list")"
        case .profilePrompt: return "profilePrompt"
        }
    }
}

/// Entwurf von „Spot markieren". Er lebt im Modell und nicht im Sheet, weil der
/// Pick-Modus das Sheet schliesst — Name, Symbol und Freundeswahl muessen die
/// Runde ueber die Karte ueberleben.
struct NewSpotDraft: Equatable {
    var name = ""
    var emoji = SpotEmoji.options[0]
    /// 0 = mein Standort, 1 = auf der Karte gewaehlt.
    var source = 0
    var picked: CLLocationCoordinate2D?
    var shared: Set<String> = []
    /// Die Freundes-Vorauswahl wird einmal gesetzt, danach gehoert sie dem Nutzer.
    var seededShared = false

    static func == (a: NewSpotDraft, b: NewSpotDraft) -> Bool {
        a.name == b.name && a.emoji == b.emoji && a.source == b.source
            && a.shared == b.shared && a.seededShared == b.seededShared
            && a.picked?.latitude == b.picked?.latitude
            && a.picked?.longitude == b.picked?.longitude
    }
}

enum SpotEmoji {
    static let options = ["🪑", "🌳", "🌊", "🔥", "⭐️", "🏕️"]
    /// Zeichen fuers eigene Profil — Charakter statt Ort, deshalb ein eigenes Set.
    static let profile = ["🌿", "🦊", "🐙", "🎧", "🌙", "⚡️", "🍀", "🔥",
                          "🌊", "🐝", "🎸", "🍄", "☕️", "🛹", "🌵"]
}

/// Zustand des Community-Features in der App-Schicht: welches Sheet offen ist,
/// welcher Entwurf laeuft, welche Meldung steht — und der Zonen-Status einzelner
/// Punkte, den die Sheets brauchen (Spot-Position, gewaehlter Punkt).
///
/// Die Daten selbst liegen in den Stores (Kit); dieses Modell haelt nur, was zur
/// Bedienung gehoert.
@MainActor
@Observable
final class CommunityModel {
    let spots: SpotStore
    let friends: FriendStore
    let invites: InviteStore
    let settings: SettingsStore
    let sync: SyncCoordinator

    var sheet: SheetRoute?
    var draft = NewSpotDraft()
    private(set) var toast: String?

    @ObservationIgnored private let clock: GZClock
    @ObservationIgnored private let zoneStatus: (CLLocationCoordinate2D) async -> ZoneStatus?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// Zonen-Status je Punkt; Schluessel ist die gerundete Koordinate.
    private var statuses: [String: ZoneStatus] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    /// Liest den Kartenmittelpunkt im Pick-Modus (von `MapContainer` gesetzt).
    @ObservationIgnored let mapCenter = MapCenterSink()
    /// Fixture-Bestand wurde gesetzt — ein zweiter Lauf wuerde die Route erneut
    /// anfahren und den Screenshot verwackeln.
    @ObservationIgnored var didSeedFixtures = false

    init(database: AppDatabase, gateway: any CloudGateway = NoCloudGateway(),
         clock: GZClock = SystemClock(),
         zoneStatus: @escaping (CLLocationCoordinate2D) async -> ZoneStatus?) {
        self.clock = clock
        self.zoneStatus = zoneStatus
        spots = SpotStore(database, clock: clock)
        friends = FriendStore(database)
        invites = InviteStore(database)
        settings = SettingsStore(database)
        sync = SyncCoordinator(gateway: gateway, spots: spots, friends: friends,
                               invites: invites, settings: settings, clock: clock)
    }

    var now: Date { clock.now }

    // MARK: - Sheets

    /// Der Pick-Modus hat kein Sheet, und die Profil-Frage tritt zurueck, solange
    /// ein anderes Sheet offen ist — sonst ueberdeckte sie eine Handlung, die der
    /// Nutzer gerade selbst begonnen hat.
    var presentedSheet: SheetRoute? {
        if let sheet { return sheet == .pick ? nil : sheet }
        return sync.state.profilePrompt ? .profilePrompt : nil
    }

    var isPicking: Bool { sheet == .pick }

    func openNewSpot() {
        draft = NewSpotDraft()
        sheet = .newspot
    }

    func startPicking() { sheet = .pick }

    func confirmPick() {
        GZ.haptic()
        if let center = mapCenter.read?() { draft.picked = center }
        sheet = .newspot
    }

    func cancelPick() {
        GZ.haptic()
        if draft.picked == nil { draft.source = 0 }
        sheet = .newspot
    }

    func closeSheet() {
        // Die Profil-Frage darf nicht sofort wiederkommen, wenn der Nutzer sie
        // wegwischt — „uebersprungen" ist eine Antwort.
        if presentedSheet == .profilePrompt, sheet == nil {
            run { try await self.sync.skipProfilePrompt() }
        }
        sheet = nil
    }

    // MARK: - Meldungen

    /// Toast wie v1: 2600 ms, dann still verschwinden.
    func notice(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2600))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// Cloud-Aktion mit ehrlichem Ausgang: klappt der Write nicht, sagt es die
    /// App und der lokale Bestand bleibt, wie er war (der Sync schreibt
    /// Cloud-zuerst).
    func run(_ action: @escaping () async throws -> Void) {
        GZ.haptic()
        Task { [weak self] in
            do {
                try await action()
            } catch {
                self?.notice(cloudMessage(error))
            }
        }
    }

    // MARK: - Abgeleitetes

    func spot(id: String) -> Spot? { spots.spot(id: id) }

    func activeInvitation(spotId: String) -> Invitation? {
        invites.activeFor(spotId: spotId, now: now)
    }

    /// Spot-Marker der Karte (Variante A). Ring `ok` bei ≤ 75 m.
    func spotPins(user: CLLocationCoordinate2D?) -> [SpotPinState] {
        spots.spots.map { spot in
            let near = user.map { Geo.distanceM($0, spot.coordinate) <= 75 } ?? false
            return SpotPinState(id: spot.id, emoji: spot.emoji, isNear: near,
                                stackPhotos: [], snapCount: 0, frontSnapID: nil,
                                latitude: spot.lat, longitude: spot.lng)
        }
    }

    /// Freunde, mit denen dieser Spot noch nicht geteilt ist.
    func shareable(_ spot: Spot) -> [Friend] {
        friends.friends.filter { !spot.participantIds.contains($0.id) }
    }

    // MARK: - Zonen-Status einzelner Punkte

    private func key(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.6f,%.6f", coordinate.latitude, coordinate.longitude)
    }

    /// `nil` = noch unbekannt (die Sheets zeigen dann „Status wird geprüft …").
    func status(at coordinate: CLLocationCoordinate2D?) -> ZoneStatus? {
        guard let coordinate else { return nil }
        return statuses[key(coordinate)]
    }

    /// Von den Sheets ueber `.task(id:)` angestossen — kein Nachladen im Getter,
    /// sonst rechnete jeder Render eine Kachel neu.
    func loadStatus(at coordinate: CLLocationCoordinate2D?) async {
        guard let coordinate else { return }
        let id = key(coordinate)
        guard statuses[id] == nil, !loading.contains(id) else { return }
        loading.insert(id)
        let result = await zoneStatus(coordinate)
        loading.remove(id)
        guard let result else { return }
        statuses[id] = result
    }
}

/// Kartenmittelpunkt auf Zuruf. `MapContainer` traegt die Leseschliesse ein,
/// der Pick-Modus ruft sie beim Bestaetigen — so kennt die App-Schicht die
/// Karte nicht und die Karte nicht die App-Schicht.
@MainActor
final class MapCenterSink {
    var read: (() -> CLLocationCoordinate2D?)?
    init() {}
}
