#if DEBUG
import CoreLocation
import GreenZonesKit
import SwiftUI
import UIKit

/// Fixture-Snaps der Screenshot-Routen (SPEC 12/14.4).
///
/// Die vier Bilder sind die Duotone-Fixtures aus dem Spike — keine Fremdfotos,
/// keine Personen. Sie laufen durch DIESELBE Pipeline wie eine echte Aufnahme
/// (verkleinern, drehen, GPS raus) und landen als echte Dateien im
/// Fixture-Ablageort: das Bild im Screenshot ist damit dasselbe Bild, das die
/// App auch sonst zeigt, nur die Quelle ist eine andere.
///
/// Nur `#if DEBUG`, und die JPEGs sind in Release/Distribution aus dem Bundle
/// ausgeschlossen (`EXCLUDED_SOURCE_FILE_NAMES` in `project.yml`).
enum SnapFixtures {
    static let names = ["snap1", "snap2", "snap3", "snap4"]

    static func data(_ name: String) -> Data? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg") else { return nil }
        return try? Data(contentsOf: url)
    }

    static func image(_ name: String) -> UIImage? {
        data(name).flatMap(UIImage.init(data:))
    }

    /// Bestand der Snap-Routen. Laeuft nach dem Community-Seed, weil das Album
    /// ueber die Spot-Zone zugeordnet wird.
    @MainActor
    static func seed(_ model: CommunityModel, route: DebugRoute, clock: GZClock) async {
        let now = clock.now
        var planned: [Plan] = []

        switch route {
        case .detail, .manage, .viewer, .viewerTile, .viewerTileBack, .hideSnap, .cameraSpot,
             .spotSnap, .toastMap, .mapSpots:
            // Mockup-Zustand 1: Album mit vier Snaps, gemischte Autoren und
            // Zeiten — Uhrzeit, „gestern", Wochentag.
            planned = [
                Plan(file: "snap1", author: "f2", minutesAgo: 130, spot: "s1", scope: .spot),
                Plan(file: "snap2", author: SELF_ID, minutesAgo: 26 * 60, spot: "s1", scope: .spot),
                // Fremder Feed-Snap an meinem Spot: traegt die Marke „alle Freunde".
                Plan(file: "snap3", author: "f1", minutesAgo: 4 * 24 * 60, spot: "s1", scope: .feed),
                Plan(file: "snap4", author: SELF_ID, minutesAgo: 6 * 24 * 60, spot: "s1", scope: .spot),
            ]
        case .solo:
            // Lokaler Spot ohne Cloud: eigene Snaps liegen in der Outbox — die
            // Marke „wartet" ist hier der ehrliche Zustand, nicht Dekoration.
            planned = [
                Plan(file: "snap2", author: SELF_ID, minutesAgo: 90, spot: "s2", scope: .feed,
                     upload: .pending),
                Plan(file: "snap4", author: SELF_ID, minutesAgo: 3 * 24 * 60, spot: "s2",
                     scope: .feed, upload: .pending),
            ]
        case .freesnap, .viewerPin, .freeSnapLand:
            // Freie Snaps stehen als eigene Pins auf der Karte.
            planned = [
                Plan(file: "snap3", author: SELF_ID, minutesAgo: 40, spot: nil, scope: .feed,
                     latitude: 52.3602, longitude: 9.7418),
                Plan(file: "snap1", author: "f1", minutesAgo: 200, spot: nil, scope: .feed,
                     latitude: 52.3586, longitude: 9.7381),
            ]
        default:
            return
        }

        var snaps: [Snap] = []
        for plan in planned {
            guard let snap = build(plan, model: model, now: now) else { continue }
            snaps.append(snap)
        }
        guard !snaps.isEmpty else { return }
        try? await model.snaps.saveAll(snaps)
        await model.thumbs.load(snaps)
    }

    private struct Plan {
        let file: String
        let author: String
        let minutesAgo: Int
        let spot: String?
        let scope: SnapScope
        var upload: SnapUploadState = .done
        var latitude: Double?
        var longitude: Double?
    }

    @MainActor
    private static func build(_ plan: Plan, model: CommunityModel, now: Date) -> Snap? {
        guard let raw = data(plan.file), let processed = try? SnapPipeline.process(raw) else {
            return nil
        }
        let id = "fx-\(plan.file)-\(plan.spot ?? "free")"
        guard let original = try? model.files.writeOriginal(processed.original, id: id),
              let thumb = try? model.files.writeThumb(processed.thumb, id: id) else { return nil }

        let spot = plan.spot.flatMap { model.spot(id: $0) }
        let coordinate = CLLocationCoordinate2D(
            latitude: plan.latitude ?? spot?.lat ?? DebugEnvironment.fixtureCoordinate.latitude,
            longitude: plan.longitude ?? spot?.lng ?? DebugEnvironment.fixtureCoordinate.longitude)
        // Fremde Snaps liegen in einer fremden Zone, eigene in meiner — das
        // entscheidet spaeter, wer loeschen darf.
        let zone: String? = plan.scope == .spot ? spot?.zoneName
            : (plan.author == SELF_ID ? "feed-me" : "feed-\(plan.author)")
        return Snap(id: id,
                    authorId: plan.author,
                    createdAt: now.addingTimeInterval(-Double(plan.minutesAgo) * 60),
                    lat: coordinate.latitude,
                    lng: coordinate.longitude,
                    spotId: spot?.id,
                    spotZone: spot?.zoneName,
                    spotName: spot?.name,
                    spotEmoji: spot?.emoji,
                    scope: plan.scope,
                    zoneName: plan.upload == .done ? zone : nil,
                    recordName: plan.upload == .done ? id : nil,
                    thumbPath: thumb.path,
                    photoPath: original.path,
                    uploadState: plan.upload)
    }
}
#endif
