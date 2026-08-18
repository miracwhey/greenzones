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
    ///
    /// `packs` ist direkt nach `reloadPacks()` noch `nil`: die Liste kommt aus
    /// der Datenbank und wird asynchron nachgereicht. Der frühere `guard`
    /// darauf lief deshalb IMMER ins Leere — die Anzeige sagte nach jedem
    /// Neustart „noch nichts gesichert", und ein zweites Sichern legte ein
    /// zweites Paket an. Gemessen am 18.08.: kein einziger Aufruf kam je bis
    /// `apply`.
    func reload() {
        MLNOfflineStorage.shared.reloadPacks()
        Task { [weak self] in
            for _ in 0 ..< 20 {
                if let packs = MLNOfflineStorage.shared.packs {
                    self?.adopt(packs)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Kartenstil an einer Adresse, die ein App-Update überlebt.
    ///
    /// `MLNTilePyramidOfflineRegion` speichert die Style-Adresse **absolut** in
    /// der Paket-Datenbank. Im Bundle-Pfad steckt eine Installations-UUID, die
    /// bei jeder Installation neu vergeben wird — nach einem Update zeigt das
    /// gespeicherte Paket also auf ein Bundle, das es nicht mehr gibt, und
    /// jeder Versuch, es fortzusetzen, endet mit „URL nicht gefunden" (am
    /// 18.08. in zwei Läufen nachgestellt: Paket trug `…/4EF79918…/`, installiert
    /// war `…/81EBD4B0…/`).
    ///
    /// Deshalb liegt für die Pakete eine Kopie im Datenverzeichnis: dessen Pfad
    /// bleibt über Updates gleich. Die Karte selbst lädt weiter direkt aus dem
    /// Bundle — sie soll nicht davon abhängen, dass das Kopieren geklappt hat.
    static func stableStyleURL(dark: Bool = false) -> URL {
        let bundled = MapContainer.Coordinator.styleURL(dark: dark)
        guard bundled.isFileURL else { return bundled }
        let logger = Logger(subsystem: "de.leonvalentin.greenzones", category: "offline")
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
            let folder = support.appendingPathComponent("map", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let mirror = folder.appendingPathComponent(bundled.lastPathComponent)
            let fresh = try Data(contentsOf: bundled)
            // Nur schreiben, wenn sich etwas geändert hat: die Adresse muss
            // gleich bleiben, der Inhalt darf mit einem Update wandern.
            if (try? Data(contentsOf: mirror)) != fresh {
                try fresh.write(to: mirror, options: .atomic)
            }
            return mirror
        } catch {
            logger.error("Stil-Kopie fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            return bundled
        }
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

        // Derselbe Stil-Inhalt wie die Karte — sonst lüde das Paket andere
        // Kacheln, als die App später zeichnet, und der Vorrat wäre wertlos.
        // Die Adresse ist die update-feste Kopie, siehe `stableStyleURL`.
        let region = MLNTilePyramidOfflineRegion(
            styleURL: Self.stableStyleURL(),
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
                self.active = pack
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
        active = nil
        state = .none
    }

    #if DEBUG
    /// Vorrat UND Zwischenspeicher leeren — nur für Testläufe.
    ///
    /// Ohne das ist `testSavingTheAreaStartsARealDownload` genau EINMAL
    /// aussagekräftig: danach liegen die Kacheln im Simulator, der zweite
    /// Download ist sofort fertig und meldet nie „Lädt". Der Lauf wird rot,
    /// ohne dass etwas kaputt wäre — und kostet die nächste Sitzung eine
    /// Fehldiagnose. Der Zustand des Prüflings darf nicht vom vorigen Lauf
    /// abhängen.
    /// `resetDatabase` statt `removeAll` + `clearAmbientCache`: die Paketliste
    /// ist direkt nach dem Start noch nicht geladen (`packs` ist `nil`), ein
    /// Aufräumen über sie greift also ins Leere — gemessen, der zweite Lauf war
    /// weiterhin rot. `resetDatabase` löscht die ganze Datei, Pakete und
    /// Zwischenspeicher zusammen, und wartet nicht auf die Liste.
    func resetForTesting() {
        active = nil
        state = .none
        MLNOfflineStorage.shared.resetDatabase { [logger] error in
            if let error {
                logger.error("Kartenspeicher nicht zurückgesetzt: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    #endif

    // MARK: - Intern

    private static let context = Data("gz-umgebung".utf8)

    /// Das Paket, das dieser Lauf angelegt hat.
    private var active: MLNOfflinePack?

    /// Bestand übernehmen — und dabei aussortieren, was aus einer früheren
    /// Installation stammt und nie fertig werden kann: solche Pakete tragen
    /// eine Bundle-Adresse, die es nicht mehr gibt.
    private func adopt(_ packs: [MLNOfflinePack]) {
        let stable = Self.stableStyleURL()
        let usable = packs.filter { pack in
            guard let style = (pack.region as? MLNTilePyramidOfflineRegion)?.styleURL else { return true }
            if style == stable { return true }
            logger.log("Verwaistes Paket entfernt (Stil \(style.lastPathComponent, privacy: .public) aus alter Installation)")
            MLNOfflineStorage.shared.removePack(pack) { _ in }
            return false
        }
        // Ein ruhendes Paket führt keinen Fortschritt mit sich; ohne diese
        // Anfrage stünden Zähler und Größe auf null und die Anzeige behauptete
        // einen Anfang, den es nicht gibt.
        usable.forEach { $0.requestProgress() }
        apply(usable)
    }

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
        // Ein Fehler zählt nur für den Lauf, den der Nutzer gerade angestoßen
        // hat. Sonst kippt ein liegengebliebenes Paket aus einer früheren
        // Installation die Anzeige auf „Sichern fehlgeschlagen", während der
        // eigene Download läuft — genau das war am 18.08. zu sehen.
        if note.name == .MLNOfflinePackError, active !== pack { return }
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
