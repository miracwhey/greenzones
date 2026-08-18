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

    /// Aus WELCHEM Snap der Betrachter hervorgeht: die Album-Kachel oder der
    /// freie Snap-Pin, beide tragen das Bild schon. Ohne Herkunft (etwa im
    /// Melden-Screenshot) blendet er auf wie bisher — das ist ein ehrlicher
    /// Ausgang, kein Sonderfall zum Verstecken.
    ///
    /// Nur die Id, nicht das Rechteck: der Karten-Pin wandert, waehrend der
    /// Betrachter offen ist (der Tap zentriert ihn erst). Ein beim Oeffnen
    /// festgehaltenes Rechteck waere auf dem Rueckweg falsch — das Bild floege
    /// dorthin, wo der Pin einmal lag.
    private(set) var morphSnapId: String?
    /// Solange das Bild unterwegs ist, zeigt der Betrachter seines NICHT —
    /// sonst laegen zwei Fotos uebereinander und der Weg waere umsonst.
    private(set) var morphInFlight = false

    /// Wohin das Bild gerade unterwegs ist. Frueher aus dem Stand geraten
    /// („steht er unten, geht es hoch") — das trug, solange jeder Flug im
    /// Vollbild endete. Der frisch aufgenommene Snap faengt aber IM Vollbild an
    /// und will zur Karte, und dort waere die Vermutung falsch herum.
    enum MorphDirection { case toFullscreen, toOrigin }
    private(set) var morphDirection: MorphDirection = .toFullscreen

    /// Welches Vollbild am oberen Ende des Weges steht. Der Betrachter zeigt das
    /// GANZE Bild, der Sucher einen formatfuellenden Ausschnitt — zwei
    /// verschiedene Flaechen. Mit der falschen sprigne das Foto im ersten Frame.
    enum MorphTop { case viewer, viewfinder }
    private(set) var morphTop: MorphTop = .viewer
    /// Nach der Landung soll der Pin aufploppen — der Snap, um den es geht.
    @ObservationIgnored private var popInAfterMorph: String?
    /// Der Pop-in folgt einem Flug: das Foto steht dann schon in voller Groesse
    /// da, der Pin uebernimmt nur noch. Ein Sprung aus dem Nichts waere hier
    /// eine zweite Ankunft fuer dasselbe Bild.
    private(set) var popInIsLanding = false

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

    /// Die laufende Einladung dieses Spots — sofern sie MICH betrifft.
    ///
    /// Seit dem 18.08. gilt eine Einladung einer Teilmenge der Spot-Runde
    /// (Leon: „fuenf Kollegen, davon zwei einladen"). Wer nicht gemeint ist,
    /// sieht hier nichts — und bekommt auch keine Mitteilung. Der Filter sitzt
    /// an dieser einen Stelle, weil jede Ansicht die Einladung von hier holt.
    ///
    /// **Grenze, die ehrlich bleiben muss:** die Einladung liegt in der
    /// geteilten Spot-Zone, und ein Share deckt die ganze Zone ab. Das hier ist
    /// eine Entscheidung der App darueber, was sie zeigt und meldet — keine
    /// Sperre von iCloud. Deshalb sagt die Oberflaeche „bekommen Bescheid",
    /// nicht „nur sie sehen es".
    func activeInvitation(spotId: String) -> Invitation? {
        guard let invitation = invites.activeFor(spotId: spotId, now: now) else { return nil }
        let participants = spots.spot(id: spotId)?.participantIds ?? []
        guard invitation.concerns(SELF_ID, spotParticipants: participants) else { return nil }
        return invitation
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

    /// Wo die Snaps gerade auf dem Schirm liegen. Album-Kacheln melden sich
    /// hier an, Karten-Pins ebenso — beide tragen das Bild schon, und aus
    /// beiden soll der Betrachter hervorgehen.
    ///
    /// Als Register statt als Parameter: sonst muesste jeder Aufrufer die
    /// Geometrie kennen und weiterreichen, und die Karte koennte es gar nicht
    /// (ihre Pins sind UIKit-Ansichten). So schlaegt `openViewer` die Herkunft
    /// selbst nach, und wer keine gemeldet hat, bekommt eben keine.
    @ObservationIgnored private var snapRects: [String: MorphRect] = [:]
    /// Die Karte kennt die Lage ihrer Pins nur auf Nachfrage — sie aendert sich
    /// bei jeder Kamerabewegung, laufend zu melden waere Arbeit pro Frame.
    @ObservationIgnored let mapPinRects = MapPinRectSink()

    func noteSnapRect(_ id: String, _ frame: MorphRect?) {
        if let frame { snapRects[id] = frame } else { snapRects.removeValue(forKey: id) }
    }

    /// Wo der Snap gerade auf dem Schirm liegt — Kachel oder Karten-Pin.
    func snapRect(_ id: String) -> MorphRect? {
        snapRects[id] ?? mapPinRects.read?(id)
    }

    /// Wo der Pin eines Snaps liegen WIRD — fuer den Flug aus dem Sucher, bevor
    /// die Karte ihn gezeichnet hat.
    func snapRect(at coordinate: CLLocationCoordinate2D) -> MorphRect? {
        mapPinRects.readAt?(coordinate)
    }

    func openViewer(_ source: SnapSource, index: Int = 0, hide: Bool = false) {
        let snaps = visibleSnaps(source)
        let opened = snaps.indices.contains(index) ? snaps[index] : nil
        let origin = opened.map(\.id).flatMap { snapRect($0) != nil ? $0 : nil }
        morphSnapId = origin
        morphDirection = .toFullscreen
        morphTop = .viewer
        morphInFlight = origin != nil
        cover = .viewer(source: source, index: index, hide: hide)
    }

    /// Das Bild ist angekommen — ab jetzt zeigt der Betrachter seines.
    func morphArrived() { morphInFlight = false }

    /// Das Bild ist zurueck in der Kachel. Das Vollbild ist da laengst weg —
    /// hier faellt nur noch die Herkunft.
    func morphReturned() {
        // Der Pin uebernimmt vom fliegenden Bild und setzt sich — erst jetzt,
        // nicht schon beim Ausloesen: sonst ploppt er, waehrend das Bild noch
        // unterwegs zu ihm ist, und beide zeigen dasselbe Foto.
        if let id = popInAfterMorph {
            popInSnapId = id
            popInIsLanding = true
            popInAfterMorph = nil
        }
        morphSnapId = nil
        morphInFlight = false
        cover = nil
    }

    func closeCover() {
        // Gibt es eine Herkunft, faehrt das Bild dorthin zurueck — und das
        // Vollbild geht SOFORT, nicht erst danach. Der Flieger lebt ueber dem
        // Vollbild und ueberlebt es; bliebe der schwarze Grund bis zum Ende
        // stehen, schrumpfte das Bild in eine leere Flaeche statt zurueck ins
        // Blatt. Genau so sah es im ersten Rueckweg-Bild aus.
        if let id = morphSnapId, snapRect(id) != nil {
            morphDirection = .toOrigin
            morphInFlight = true
            cover = nil
        } else {
            morphSnapId = nil
            cover = nil
        }
    }

    /// Schliessen ohne Rueckweg — fuer den Wisch nach unten, der das Bild
    /// bereits selbst bewegt hat: von dort in die Kachel zurueckzuspringen
    /// waere ein zweiter, widersprechender Weg.
    func dismissCover() {
        morphSnapId = nil
        morphInFlight = false
        cover = nil
    }

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
            #if DEBUG
            // Die Startmarke fuer die Bildabnahme steht HIER, nicht vor dem
            // Aufruf: davor liefe die Bildverarbeitung mit in die Messung, und
            // die dauert laenger als mancher Frame, den sie messen soll. Und vor
            // dem Guard, weil auch der Spot-Fall gemessen wird — dort waechst
            // der Faecher des vorhandenen Pins.
            DebugEnvironment.motionGo()
            #endif
            // Nur freie Snaps ploppen: am Spot waechst stattdessen der Faecher
            // des bestehenden Pins (SpotPinView.playStackGrow).
            guard snap.isFree else { return }
            // Wenn die Karte sagen kann, wo der Pin landen wird, fliegt das Bild
            // aus dem Sucher dorthin und der Pin ploppt erst bei der Ankunft.
            // Kann sie es nicht (Punkt ausserhalb des Schirms), ploppt er sofort
            // — ein Bild, das aus dem Bildrand heraus einschwebt, waere eine
            // Herkunft, die niemand gesehen hat.
            if let target = snapRect(at: snap.coordinate) {
                popInAfterMorph = snap.id
                noteSnapRect(snap.id, target)
                morphSnapId = snap.id
                morphDirection = .toOrigin
                morphTop = .viewfinder
                morphInFlight = true
            } else {
                popInSnapId = snap.id
                popInIsLanding = false
            }
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            // ERST aufnehmen, DANN den Sucher raeumen. Vorher lief es umgekehrt:
            // die Kamera ging sofort zu, die Bildverarbeitung brauchte ihre Zeit,
            // und der Pin erschien danach aus dem Nichts. Jetzt steht der Sucher,
            // bis das Bild ihn verlaesst — es fliegt ueber ihm hinweg, waehrend
            // er ausblendet.
            await self.capture(data, at: coordinate, spot: spot, scope: scope)
            // NICHT `dismissCover`: das raeumt auch die Herkunft ab und wuerde
            // den gerade gestarteten Flug mitnehmen. Hier geht nur der Sucher.
            self.cover = nil
        }
    }

    /// Das Aufploppen ist ein Ereignis, kein Zustand: die Karte quittiert es,
    /// damit ein zweiter Render den Pin nicht erneut hereinspringen laesst.
    func consumePopIn() {
        popInSnapId = nil
        popInIsLanding = false
    }

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

/// Lage eines freien Snap-Pins auf dem Schirm, auf Nachfrage. Die Karte setzt
/// die Closure, das Model fragt — genauso wie beim Kartenmittelpunkt.
@MainActor
final class MapPinRectSink {
    var read: ((String) -> MorphRect?)?
    /// Dieselbe Flaeche fuer einen Punkt, an dem noch kein Pin steht: ein frisch
    /// aufgenommener Snap fliegt aus dem Sucher an seinen Platz, bevor die Karte
    /// ihn gezeichnet hat.
    var readAt: ((CLLocationCoordinate2D) -> MorphRect?)?
    init() {}
}
