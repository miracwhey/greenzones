import GreenZonesKit
import SwiftUI
import UIKit

/// Woher der Betrachter seine Bilder nimmt.
///
/// Ein Spot zeigt sein Album (blaetterbar), ein freier Snap steht fuer sich —
/// auf der Karte hat ihn jemand einzeln angetippt, eine Sammlung gaebe es dort
/// gar nicht.
enum SnapSource: Equatable {
    case spot(spotId: String)
    case free(snapId: String)

    var key: String {
        switch self {
        case .spot(let id): return "spot-\(id)"
        case .free(let id): return "free-\(id)"
        }
    }
}

/// Kamera und Betrachter teilen sich EINE Praesentation: zwei `fullScreenCover`
/// an derselben View schliessen einander aus — die zweite gewinnt, die erste
/// zuendet nie (Spike-Befund).
enum SnapCover: Identifiable, Equatable {
    /// `spotId` gesetzt = der Snap gehoert explizit zu diesem Spot, egal wie
    /// weit weg man steht (Leon-Korrektur: kein Naehe-Zwang aus dem Sheet).
    case camera(spotId: String?)
    /// `hide` faehrt den Ausblenden-Dialog direkt an (Screenshot-Schalter). Der
    /// Wert reist IM Item mit — ein daneben liegender `@State` kaeme im
    /// Praesentations-Closure zu spaet an.
    case viewer(source: SnapSource, index: Int, hide: Bool)

    var id: String {
        switch self {
        case .camera(let spotId): return "camera-\(spotId ?? "free")"
        case .viewer(let source, let index, let hide): return "viewer-\(source.key)-\(index)-\(hide)"
        }
    }
}

/// Vorschaubilder von der Platte, einmal geladen und gehalten.
///
/// Kacheln UND Karten-Pins lesen hier — zwei Caches waeren zwei Ladewege fuer
/// dasselbe Bild. Gelesen wird nur aus dem Speicher (`image(id:)`), gefuellt
/// ueber `load(_:)`: ein Dateizugriff im Render-Getter wuerde bei jedem Frame
/// erneut laufen.
@MainActor
@Observable
final class SnapThumbs {
    private var images: [String: UIImage] = [:]

    @ObservationIgnored private let files: SnapFiles
    @ObservationIgnored private var loading: Set<String> = []
    /// Pfade, die es nicht (mehr) gibt — ein zweiter Versuch faende dieselbe
    /// Leere. Neu geschriebene Dateien tragen einen neuen Pfad und fallen
    /// deshalb nicht unter diese Sperre.
    @ObservationIgnored private var missing: Set<String> = []

    init(files: SnapFiles = SnapFiles()) {
        self.files = files
    }

    func image(id: String) -> UIImage? { images[id] }

    /// Fehlende Vorschaubilder nachziehen. Die Datei liest ein Hintergrund-Task,
    /// dekodiert wird auf dem Hauptaktor — `Data` reist zwischen Aktoren, ein
    /// `UIImage` nicht.
    func load(_ snaps: [Snap]) async {
        for snap in snaps {
            guard images[snap.id] == nil, !loading.contains(snap.id) else { continue }
            guard let path = snap.thumbPath, !missing.contains(path) else { continue }
            loading.insert(snap.id)
            let data = await Task.detached(priority: .userInitiated) {
                FileManager.default.contents(atPath: path)
            }.value
            loading.remove(snap.id)
            guard let data, let image = UIImage(data: data) else {
                missing.insert(path)
                continue
            }
            images[snap.id] = image
        }
    }

    /// Snap ist weg (geloescht oder ausgeblendet): das Bild darf nicht in einem
    /// Pin weiterleben.
    func forget(id: String) {
        images[id] = nil
    }
}
