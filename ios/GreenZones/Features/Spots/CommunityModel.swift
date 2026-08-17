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
    /// W5: Bestand der Snaps (eigene wie fremde) …
    let snaps: SnapStore
    /// … und ihr Weg: Aufnahme, Outbox, Vorschaubilder, Loeschen, Melden.
    let snapSync: SnapCoordinator
    /// Vorschaubilder von der Platte — Kacheln und Karten-Pins lesen dieselben.
    let thumbs: SnapThumbs

    var sheet: SheetRoute?
    /// W5: Vollbild ueber allem — Kamera oder Betrachter. Eines von beiden, nie
    /// beides: zwei `fullScreenCover` an derselben View schliessen einander aus.
    var cover: SnapCover?
    var draft = NewSpotDraft()
    private(set) var toast: String?
    /// Frisch aufgenommener freier Snap — sein Pin ploppt einmal auf (SPEC 9).
    private(set) var popInSnapId: String?

    /// Wo die Bilder liegen — Bestand, Aufnahme und Fixture-Laeufe teilen sich
    /// dieselbe Basis.
    @ObservationIgnored let files: SnapFiles
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
         clock: GZClock = SystemClock(), files: SnapFiles = SnapFiles(),
         zoneStatus: @escaping (CLLocationCoordinate2D) async -> ZoneStatus?) {
        self.clock = clock
        self.zoneStatus = zoneStatus
        self.files = files
        spots = SpotStore(database, clock: clock)
        friends = FriendStore(database)
        invites = InviteStore(database)
        settings = SettingsStore(database)
        sync = SyncCoordinator(gateway: gateway, spots: spots, friends: friends,
                               invites: invites, settings: settings, clock: clock)
        // W5: EIN Dateiort fuer Bestand, Aufnahme und Anzeige — zwei
        // `SnapFiles`-Instanzen mit verschiedenen Basen wuerden aneinander
        // vorbei schreiben und lesen.
        snaps = SnapStore(database, files: files)
        snapSync = SnapCoordinator(store: snaps, gateway: gateway, files: files, clock: clock)
        thumbs = SnapThumbs(files: files)
        // Der Vollabzug traegt auch die Snaps. Der `SyncCoordinator` kennt sie
        // nicht — er reicht den Snapshot hierher durch, und zwar mit dem
        // Spot-Bestand von NACH dem Merge (die Zuordnung laeuft ueber Zonen).
        sync.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            await self.snapSync.apply(snapshot, spots: self.spots.spots)
        }
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

    /// Spot-Marker der Karte (Variante A). Ring `ok` bei ≤ 75 m; der Faecher
    /// traegt die zwei neuesten Snaps des Albums, der Chip den Rest.
    func spotPins(user: CLLocationCoordinate2D?) -> [SpotPinState] {
        spots.spots.map { spot in
            let near = user.map { Geo.distanceM($0, spot.coordinate) <= 75 } ?? false
            let album = snaps.album(of: spot)
            let photos = album.prefix(2).compactMap { thumbs.image(id: $0.id) }
            return SpotPinState(id: spot.id, emoji: spot.emoji, isNear: near,
                                stackPhotos: photos, snapCount: album.count,
                                frontSnapID: album.first?.id,
                                latitude: spot.lat, longitude: spot.lng)
        }
    }

    /// W5: freie Snaps als eigene Pins. Ohne geladenes Vorschaubild steht der Pin
    /// trotzdem — das Bild kommt nach, der Ort ist schon wahr.
    func freeSnapPins() -> [FreeSnapPinState] {
        snaps.freePins.map { snap in
            FreeSnapPinState(id: snap.id, photo: thumbs.image(id: snap.id),
                             latitude: snap.lat, longitude: snap.lng)
        }
    }

    // MARK: - Snaps (W5)

    /// Album eines Spots: eigene Spot-Snaps ∪ Feed-Snaps am selben Spot.
    func album(of spot: Spot) -> [Snap] { snaps.album(of: spot) }

    /// Anstoss-Schluessel fuer die Vorschaubilder: Id UND Pfad. Ein Thumb, der
    /// aus der Cloud nachkommt, aendert nur den Pfad — an einer reinen Id-Liste
    /// würde er nie bemerkt.
    var thumbKey: String {
        snaps.snaps.map { "\($0.id)|\($0.thumbPath ?? "")" }.joined(separator: ",")
    }

    func loadThumbs() async { await thumbs.load(snaps.snaps) }

    /// Was der Betrachter zeigt: das ganze Album eines Spots, oder genau den
    /// einen freien Snap, den jemand auf der Karte angetippt hat.
    func visibleSnaps(_ source: SnapSource) -> [Snap] {
        switch source {
        case .spot(let spotId):
            guard let spot = spot(id: spotId) else { return [] }
            return album(of: spot)
        case .free(let snapId):
            return snaps.snap(id: snapId).map { [$0] } ?? []
        }
    }

    func openCamera(spotId: String? = nil) {
        GZ.haptic()
        cover = .camera(spotId: spotId)
    }

    func openViewer(_ source: SnapSource, index: Int = 0, report: Bool = false) {
        cover = .viewer(source: source, index: index, report: report)
    }

    func closeCover() { cover = nil }

    /// Aufnahme abschliessen: Datei, Bestand, Vorschau, Pin. Der Upload laeuft
    /// hinterher (Outbox) — sichtbar ist der Snap sofort.
    func capture(_ data: Data, at coordinate: CLLocationCoordinate2D?, spot: Spot?,
                 scope: SnapScope) async {
        // Ein Snap braucht einen Ort: er ist ein Punkt auf der Karte, kein
        // Bild in einem Ordner. Ohne Standort und ohne Spot gibt es keinen.
        guard let position = coordinate ?? spot?.coordinate else {
            notice("Ohne Standort kann der Snap nicht auf die Karte — Ortung erlauben und nochmal.")
            return
        }
        do {
            let snap = try await snapSync.capture(data, at: position, spot: spot, scope: scope)
            await thumbs.load([snap])
            // Nur freie Snaps ploppen: am Spot waechst stattdessen der Faecher
            // des bestehenden Pins (SpotPinView.playStackGrow).
            popInSnapId = snap.isFree ? snap.id : nil
        } catch {
            notice("Das Foto konnte nicht gespeichert werden.")
        }
    }

    /// Auslösen aus der Kamera: erst das Vollbild schliessen, dann den Snap
    /// anlegen. Andersherum liefe die Feder (Pin-Pop-in, wachsender Faecher)
    /// hinter dem Vollbild ab und niemand saehe sie — der Kern-Moment aus der
    /// SPEC waere weg. Der Auftrag haengt am Modell, nicht an der Kamera-View:
    /// die ist beim Anlegen laengst verschwunden.
    func captureAndClose(_ data: Data, at coordinate: CLLocationCoordinate2D?, spot: Spot?,
                         scope: SnapScope) {
        closeCover()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(340))
            await self?.capture(data, at: coordinate, spot: spot, scope: scope)
        }
    }

    /// Das Aufploppen ist ein Ereignis, kein Zustand: die Karte quittiert es,
    /// damit ein zweiter Render den Pin nicht erneut hereinspringen laesst.
    func consumePopIn() { popInSnapId = nil }

    /// Loeschen darf der Autor — und der Gastgeber in seiner eigenen Spot-Zone
    /// (Zone-Owner-Recht, SPEC 7). Fremde Feed-Snaps am eigenen Spot liegen in
    /// fremder Zone: dort bleibt nur Melden.
    func canDelete(_ snap: Snap) -> Bool {
        if snap.isMine { return true }
        guard snap.scope == .spot, let zone = snap.zoneName else { return false }
        return spots.spots.contains { $0.zoneName == zone && $0.isMine }
    }

    /// Beschriftung einer Album-Kachel: „Ich · gestern", „Tara · 19:41".
    func snapCaption(_ snap: Snap) -> String {
        let who = snap.isMine ? "Ich" : (friends.friend(id: snap.authorId).map(friendLabel) ?? "Freund")
        return "\(who) · \(snapWhen(snap.createdAt, now: now))"
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
