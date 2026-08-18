#if DEBUG
import CoreLocation
import GreenZonesKit
import SwiftUI

/// Fixture-Bestand fuer die Screenshot-Routen — dieselben Daten wie
/// `client/shot_spots.mjs`, damit die Bilder des Neubaus mit denen von v1
/// vergleichbar sind.
///
/// Nur `#if DEBUG` und nur in die In-Memory-DB (SPEC 14.4): keine echten
/// Personen, keine Fremdfotos, kein Weg in einen Release-Build.
enum CommunityFixtures {
    /// Zeiten relativ zu „jetzt": der naechste 20-Uhr-Abend, der noch mindestens
    /// eine Stunde entfernt ist — sonst haengt das Bild an der Uhrzeit des Laufs.
    static func evening(_ now: Date, calendar: Calendar = .current) -> Date {
        func twenty(_ dayOffset: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: now) ?? now
            var parts = calendar.dateComponents([.era, .year, .month, .day], from: day)
            parts.hour = 20
            parts.minute = 0
            parts.second = 0
            parts.nanosecond = 0
            return calendar.date(from: parts) ?? day
        }
        let today = twenty(0)
        return today < now.addingTimeInterval(3600) ? twenty(1) : today
    }

    /// Beide Spots liegen um die Fixture-Position (Maschsee-Nordufer) herum und
    /// passen bei Startzoom neben den Puck ins Bild — sonst zeigt „map_spots"
    /// nur einen halben Marker am Rand. s1 ist geteilt (zoneName →
    /// „Einladen"-CTA), s2 bleibt lokal („Mit Freunden teilen"): beide Welten
    /// sichtbar.
    static func spots(_ now: Date) -> [Spot] {
        [
            Spot(id: "s1", name: "Unsere Bank", emoji: "🪑", lng: 9.7375, lat: 52.3613,
                 createdAt: now.addingTimeInterval(-86_400),
                 zoneName: "spot-s1", ownerId: SELF_ID, participantIds: ["f1", "f2"],
                 shareURL: "https://www.icloud.com/share/s1"),
            Spot(id: "s2", name: "Maschsee-Ecke", emoji: "🌳", lng: 9.7430, lat: 52.3567,
                 createdAt: now.addingTimeInterval(-43_200)),
        ]
    }

    /// Marcel hat ein Zeichen, Tara nicht — beide Avatar-Faelle stehen im Bild.
    static let friends = [
        Friend(id: "f1", name: "Marcel", emoji: "🎧", color: "#7C5CFF",
               friendshipZone: "friend-f1"),
        Friend(id: "f2", name: "Tara", emoji: nil, color: "#0A9B8E",
               friendshipZone: "friend-f2"),
    ]

    @MainActor
    static func seed(_ model: CommunityModel, route: DebugRoute, clock: GZClock) {
        guard !model.didSeedFixtures else { return }
        model.didSeedFixtures = true
        let now = clock.now
        let t20 = evening(now)
        let t21 = t20.addingTimeInterval(3600)

        var spotList = spots(now)
        var friendList = friends
        var invitations: [Invitation] = []
        var profile = Profile(displayName: "Leon", emoji: "🌿")
        var profileAsked = false

        func invitation(hostId: String = SELF_ID, replies: [Reply] = []) -> Invitation {
            Invitation(id: "i1", spotId: "s1", hostId: hostId,
                       time: t20,
                       createdAt: now.addingTimeInterval(-3600),
                       cancelled: false, replies: replies)
        }

        switch route {
        case .mapSpots:
            invitations = [invitation()]
        case .manage:
            invitations = [invitation(replies: [
                Reply(participantId: "f1", status: .ind),
                Reply(participantId: "f2", status: .ind, arrivalTime: t21),
            ])]
        case .reply:
            // Fremde Einladung, eigene Antwort fehlt → Antwortraum des Empfaengers.
            invitations = [invitation(hostId: "f1",
                                      replies: [Reply(participantId: "f2", status: .ind)])]
        case .solo:
            // Leons Erstnutzer-Fall: 0 Freunde, ein lokaler Spot.
            spotList = [spotList[1]]
            friendList = []
        case .welcome:
            // Das eigene Profil ist der Pruefling: der leere Zustand ist echt,
            // nicht gestellt.
            profile = Profile()
        case .profileEmpty:
            // Zustand NACH dem Ueberspringen: der Schritt ruht, die Liste traegt
            // den offenen Hinweis.
            profile = Profile()
            profileAsked = true
        default:
            break
        }

        let finalSpots = spotList
        let finalFriends = friendList
        let finalInvitations = invitations
        let finalProfile = profile
        let asked = profileAsked

        Task { @MainActor in
            try? await model.friends.replaceAll(finalFriends)
            try? await model.spots.replaceAll(finalSpots)
            try? await model.invites.replaceAll(finalInvitations)
            try? await model.settings.setProfile(finalProfile)
            try? await model.settings.setProfileAsked(asked)
            // W5: Snaps NACH den Spots — das Album haengt an der Spot-Zone.
            if route.needsSnaps {
                await SnapFixtures.seed(model, route: route, clock: clock)
            }
            // Der Sync laeuft auch im Fixture-Lauf: ohne CloudKit meldet er
            // ehrlich `couldNotDetermine` — genau der Hinweis, den die Bilder
            // zeigen sollen. Der leere Snapshot merged nichts, der Bestand
            // bleibt wie gesetzt.
            await model.sync.start()
            applyRoute(model, route: route, now: now)
        }
    }

    /// Faehrt den Zustand an, den in der App ein Tap setzen wuerde.
    private static func applyRoute(_ model: CommunityModel, route: DebugRoute, now: Date) {
        // Erst die Karte settlen lassen — sonst zeigt der Screenshot ein Sheet
        // ueber halb geladenen Tiles. `GZ_UI_SETTLE` hebt die Wartezeit fuer
        // Bewegungsbilder an.
        DispatchQueue.main.asyncAfter(deadline: .now() + DebugEnvironment.uiSettle) {
            if !route.announcesMotionItself { DebugEnvironment.motionGo() }
            switch route {
            case .newspot:
                model.openNewSpot()
                model.draft.name = "Unsere Bank"
            case .pick:
                model.openNewSpot()
                model.draft.name = "Unsere Bank"
                model.draft.source = 1
                model.startPicking()
            case .detail, .manage, .reply:
                model.sheet = .detail(spotId: "s1")
            case .solo:
                model.sheet = .detail(spotId: "s2")
            case .invite:
                model.sheet = .invite(spotId: "s1")
            case .sent:
                model.sheet = .invite(spotId: "s1")
                // Geteilter Spot ohne CloudKit: der Sende-Versuch endet ehrlich
                // im Abbruch (Toast, Sheet bleibt offen, Bestand unveraendert).
                // Spaet genug, dass der Toast (2600 ms) beim Ausloesen des
                // Screenshots (GZ_SETTLE, Default 9 s) noch steht.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    model.run {
                        try await model.sync.invite(spotId: "s1", time: evening(now))
                    }
                }
            case .friends, .profileEmpty:
                model.sheet = .friends(intent: nil)
            case .profile:
                // Wie der Tap auf die eigene Profilzeile in der Liste.
                model.sheet = .friends(intent: .edit)
            case .welcome, .mapSpots, .map, .statusDetail, .info:
                break
            case .toastMap:
                // Derselbe Weg wie jede echte Meldung — nur der Anlass ist
                // gestellt. Der Text ist der laengste, den die App kennt.
                model.notice("Ohne Standort kann der Snap nicht auf die Karte — Ortung erlauben und nochmal.")
            case .freeSnapLand:
                // Wie der Ausloeser in der Kamera: dieselbe `captureAndClose`,
                // nur ohne Sucher davor. Ohne Spot in Reichweite wird daraus ein
                // freier Snap — der Fall, um den es in dieser Bewegung geht.
                if let data = SnapFixtures.data("snap4") {
                    model.captureAndClose(data, at: DebugEnvironment.fixtureCoordinate,
                                          spot: nil, scope: .feed)
                }
            case .spotSnap:
                // Der echte Aufnahmeweg, nur ohne Kamera: dasselbe `capture`,
                // das der Ausloeser ruft. Die Startmarke faellt DANACH — vorher
                // liefe die Bildverarbeitung mit in die Messung, und der Faecher
                // haette sich noch gar nicht geruehrt.
                if let spot = model.spot(id: "s1"), let data = SnapFixtures.data("snap2") {
                    Task { @MainActor in
                        await model.capture(data, at: spot.coordinate, spot: spot, scope: .spot)
                    }
                }
            // W5: Karte mit freien Snap-Pins — kein Blatt, die Pins sind der Prüfling.
            case .freesnap:
                break
            case .viewerPin:
                // Wie der Tap auf den Pin: derselbe Aufruf, dieselbe Herkunft.
                // Die Pins muessen dafuer schon auf der Karte liegen — deshalb
                // erst nach dem Settle, und die Startmarke sitzt hier.
                if let pin = model.freeSnapPins().first {
                    model.openViewer(.free(snapId: pin.id))
                }
            case .camera:
                // Ohne Spot in Reichweite: derselbe Weg wie der Plus-FAB.
                model.openCamera()
            case .cameraSpot:
                // Aus dem Spot-Blatt heraus (Kontext-Chip + Sichtbarkeits-Schalter).
                // Das Blatt bleibt darunter offen: nach dem Auslösen faellt die
                // neue Kachel dorthin — daran haengt der Beweis, dass der ganze
                // Weg (Pipeline, Dateien, Bestand, Anzeige) laeuft.
                model.sheet = .detail(spotId: "s1")
                model.openCamera(spotId: "s1")
            case .viewer:
                model.openViewer(.spot(spotId: "s1"))
            case .viewerTile:
                // Der echte Weg: erst steht das Blatt, dann meldet die Kachel
                // ihre Lage, dann geht der Betrachter aus ihr hervor. Ohne die
                // Pause dazwischen kennt niemand die Herkunft, und der Morph
                // faende still nicht statt — genau der Fehler, den eine Route
                // sichtbar machen soll.
                model.sheet = .detail(spotId: "s1")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    DebugEnvironment.motionGo()
                    model.openViewer(.spot(spotId: "s1"), index: 0)
                }
            case .viewerTileBack:
                // Erst den ganzen Hinweg gehen lassen, dann schliessen wie der
                // Knopf im Betrachter. Die Marke faellt beim Schliessen.
                model.sheet = .detail(spotId: "s1")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    model.openViewer(.spot(spotId: "s1"), index: 0)
                }
                // Der Hinweg muss DURCH sein, bevor der Rueckweg beginnt — und
                // er dauert unter der Zeitlupe entsprechend laenger. Eine feste
                // Wartezeit schnitte bei jedem Dehnfaktor woanders hinein und
                // maesse dann eine Richtungsumkehr statt eines Rueckwegs.
                let flight = 1.2 + 3.0 * 0.36 * GZ.slowmo
                DispatchQueue.main.asyncAfter(deadline: .now() + flight) {
                    DebugEnvironment.motionGo()
                    model.closeCover()
                }
            case .hideSnap:
                // Index 0 ist der neueste Snap und stammt von Tara — ausblenden
                // laesst sich nur ein fremdes Bild.
                model.openViewer(.spot(spotId: "s1"), index: 0, hide: true)
            // W2-Routen: Suche und Ziel-Modus fahren ihren Zustand selbst an
            // (Overlay in `RootView`, Ziel in `AppModel.start()`). Der Community-
            // Bestand steht dann trotzdem — die Spot-Pins gehoeren zur Karte.
            case .search, .searchResults, .searchOffline, .searchOffer, .target, .targetDetail:
                break
            }
        }
    }
}
#endif
