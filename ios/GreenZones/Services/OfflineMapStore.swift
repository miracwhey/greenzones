import CoreLocation
import Foundation
import MapLibre
import os

/// Kartenbild ohne Netz.
///
/// Die Zonen liegen seit dem 18.08. vollständig im Bundle und stehen offline —
/// aber eine Karte, auf der nur farbige Flächen ohne Straßen liegen, hilft
/// niemandem im Park weiter. Zwei Wege, zusammen:
///
///  1. **Behalten, was geladen wurde.** MapLibre führt einen Zwischenspeicher;
///     im Projekt war er nie konfiguriert und lief im Standard, den das System
///     jederzeit räumen darf. Er wird hier auf eine Größe gesetzt, in die eine
///     Stadt passt.
///  2. **Vorher sichern.** Ein Gebiet um den eigenen Standort wird auf Wunsch
///     komplett heruntergeladen — für Festival, Wanderung, Zeltplatz.
///
/// Warum 20 km und Zoom 14: gemessen, nicht geschätzt. Eine Kachel ist auf
/// unserer Breite 1,5 km; bei Zoom 14 wiegt sie im Stadtgebiet rund 350 KB,
/// bei Zoom 13 nur 86 KB. 20 × 20 km bis 14 sind damit ~70 MB — dieselbe
/// Fläche bis 13 wären 6 MB, aber ohne das Detail, das man beim Suchen einer
/// Bank tatsächlich braucht (Leon-Entscheid 18.08.).
@MainActor
@Observable
final class OfflineMapStore {
    enum State: Equatable {
        case none
        /// Läuft — `fraction` ist 0…1, `bytes` das bisher Geladene.
        case downloading(fraction: Double, bytes: UInt64)
        case ready(bytes: UInt64)
        case failed(String)
    }

    private(set) var state: State = .none

    /// Kantenlänge des gesicherten Gebiets. 20 km um den Standort heißt ±10 km.
    static let radiusM: CLLocationDistance = 10_000
    static let minZoom: Double = 10
    static let maxZoom: Double = 14
    /// Platz für den automatischen Speicher. Der Standard von MapLibre ist
    /// klein genug, dass eine Stadtfahrt ihn überschreibt.
    static let ambientCacheBytes: UInt = 400 * 1024 * 1024

    private let logger = Logger(subsystem: "de.leonvalentin.greenzones", category: "offline")
    /// Die Beobachtung laeuft, solange der Store lebt — und der lebt so lange
    /// wie die App. Ein Abmelden im `deinit` waere Zeremonie ohne Fall.
    private var observers: [any NSObjectProtocol] = []

    init() {
        MLNOfflineStorage.shared.setMaximumAmbientCacheSize(Self.ambientCacheBytes) { [logger] error in
            if let error {
                // Kein Grund, den Start zu kippen — die Karte lädt weiter aus
                // dem Netz. Sichtbar muss es trotzdem sein.
                logger.error("Zwischenspeicher nicht gesetzt: \(error.localizedDescription, privacy: .public)")
            }
        }
        observe()
        reload()
    }

    /// Vorhandene Pakete einlesen — nach einem Neustart weiß die App sonst
    /// nicht, dass schon etwas gesichert ist, und böte es erneut an.
    func reload() {
        MLNOfflineStorage.shared.reloadPacks()
        guard let packs = MLNOfflineStorage.shared.packs else { return }
        apply(packs)
    }

    /// Gebiet um diesen Punkt sichern. Ein zweiter Aufruf bei laufendem
    /// Download tut nichts — der Knopf ist dann ohnehin gesperrt.
    func download(around center: CLLocationCoordinate2D) {
        if case .downloading = state { return }

        // Meter → Grad: die Breite ist konstant, die Länge schrumpft mit dem
        // Kosinus der Breite. Ohne diese Korrektur wäre das Gebiet in Hannover
        // gut ein Drittel schmaler als gedacht.
        let latDelta = Self.radiusM / 111_320
        let lonDelta = Self.radiusM / (111_320 * cos(center.latitude * .pi / 180))
        let bounds = MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: center.latitude - latDelta,
                                       longitude: center.longitude - lonDelta),
            ne: CLLocationCoordinate2D(latitude: center.latitude + latDelta,
                                       longitude: center.longitude + lonDelta))

        // Derselbe Style wie die Karte — sonst lüde das Paket andere Kacheln,
        // als die App später zeichnet, und der Vorrat wäre wertlos.
        let region = MLNTilePyramidOfflineRegion(
            styleURL: MapContainer.Coordinator.styleURL(dark: false),
            bounds: bounds, fromZoomLevel: Self.minZoom, toZoomLevel: Self.maxZoom)

        state = .downloading(fraction: 0, bytes: 0)
        MLNOfflineStorage.shared.addPack(for: region, withContext: Self.context) { [weak self] pack, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.logger.error("Paket startet nicht: \(error.localizedDescription, privacy: .public)")
                    self.state = .failed(error.localizedDescription)
                    return
                }
                pack?.resume()
            }
        }
    }

    /// Gesicherte Gebiete wieder loswerden — der Vorrat ist Speicherplatz, und
    /// wer ihn nicht mehr braucht, muss ihn ohne Umweg über die
    /// App-Deinstallation zurückbekommen.
    func removeAll() {
        guard let packs = MLNOfflineStorage.shared.packs else { return }
        for pack in packs {
            pack.suspend()
            MLNOfflineStorage.shared.removePack(pack) { _ in }
        }
        state = .none
    }

    // MARK: - Intern

    private static let context = Data("gz-umgebung".utf8)

    private func observe() {
        let center = NotificationCenter.default
        for name: NSNotification.Name in [.MLNOfflinePackProgressChanged, .MLNOfflinePackError] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in self?.handle(note) }
            })
        }
    }

    private func handle(_ note: Notification) {
        guard let pack = note.object as? MLNOfflinePack else { return }
        if note.name == .MLNOfflinePackError {
            let error = note.userInfo?[MLNOfflinePackUserInfoKey.error] as? NSError
            logger.error("Paket-Fehler: \(error?.localizedDescription ?? "unbekannt", privacy: .public)")
            state = .failed(error?.localizedDescription ?? "Download fehlgeschlagen")
            return
        }
        apply([pack])
    }

    private func apply(_ packs: [MLNOfflinePack]) {
        guard let pack = packs.first(where: { $0.context == Self.context }) ?? packs.first else {
            state = .none
            return
        }
        let progress = pack.progress
        let bytes = progress.countOfBytesCompleted
        // `countOfResourcesExpected` ist waehrend des Laufs eine Schaetzung und
        // steigt noch; erst der abgeschlossene Zustand ist die Wahrheit.
        if progress.countOfResourcesCompleted >= progress.countOfResourcesExpected,
           progress.countOfResourcesExpected > 0 {
            state = .ready(bytes: bytes)
            return
        }
        let fraction = progress.countOfResourcesExpected > 0
            ? Double(progress.countOfResourcesCompleted) / Double(progress.countOfResourcesExpected)
            : 0
        state = .downloading(fraction: min(max(fraction, 0), 1), bytes: bytes)
    }
}
