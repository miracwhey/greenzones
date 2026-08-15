import CoreLocation
import Foundation
import os

/// Der Such-Kern. Port von `client/src/lib/search/controller.ts`.
///
/// Ablauf pro Tastendruck:
///  1. Offline-Index antwortet sofort (Actor, nicht Main-Thread).
///  2. Photon wird 300 ms debounced hinterhergeschickt.
/// Jede Antwort traegt die Sequenz ihres Query-Standes; aeltere Antworten werden
/// verworfen. Fehler beider Quellen landen in einem sichtbaren State.
@MainActor
@Observable
public final class SearchController {
    // `nonisolated`, damit die Zahlen auch aus Default-Argumenten und aus
    // Tests ohne MainActor-Hop lesbar sind — sie sind Konstanten, kein Zustand.
    public nonisolated static let minQueryOffline = 2
    public nonisolated static let minQueryOnline = 3
    public nonisolated static let debounceMilliseconds = 300
    public nonisolated static let offlineLimit = 6

    /// Was die UI rendert. Wird nur ueber `emit()` gesetzt.
    public private(set) var state: SearchState = .idle(query: "", index: .unloaded, recents: [])

    private let offlineSource: any OfflineIndexSource
    private let photon: any PhotonSource
    private let recentsStore: RecentsStore
    private let debounceMilliseconds: Int
    private let offlineLimit: Int
    private let logger = Logger(subsystem: "de.leonvalentin.greenzones", category: "search")

    private var query = ""
    private var userPos: CLLocationCoordinate2D?
    private var indexState: IndexState = .unloaded
    private var offline: [SearchResult] = []
    private var online: OnlineState = .idle
    private var recents: [SearchResult] = []

    /// Monoton steigend pro Query-Aenderung — Sequenz-Guard fuer Photon.
    private var requestID = 0
    /// Eigene Sequenz fuer die Offline-Quelle: sie wird auch ohne
    /// Query-Aenderung neu befragt (`setUserPos`).
    private var offlineSeq = 0
    private var offlinePending = false
    private var debounceTask: Task<Void, Never>?

    public init(offline: any OfflineIndexSource,
                photon: any PhotonSource,
                recents recentsStore: RecentsStore,
                debounceMilliseconds: Int = SearchController.debounceMilliseconds,
                offlineLimit: Int = SearchController.offlineLimit) {
        self.offlineSource = offline
        self.photon = photon
        self.recentsStore = recentsStore
        self.debounceMilliseconds = debounceMilliseconds
        self.offlineLimit = offlineLimit
        recents = recentsStore.list()
        state = buildState()
    }

    // MARK: - Aktionen

    /// Index vorwaermen, sobald die App bereit ist — nicht erst beim ersten
    /// Tastendruck.
    public func prewarm() {
        guard case .unloaded = indexState else { return }
        ensureIndex()
        emit()
    }

    public func setQuery(_ value: String) {
        query = value
        cancelDebounce()
        // Jede Query-Aenderung entwertet laufende Photon-Antworten.
        requestID &+= 1

        let length = value.trimmingCharacters(in: .whitespacesAndNewlines).count

        if length < Self.minQueryOffline {
            resetOffline()
            online = .idle
            emit()
            return
        }

        ensureIndex()
        recomputeOffline()

        if length >= Self.minQueryOnline {
            online = .loading
            let id = requestID
            let pending = value
            let delay = debounceMilliseconds
            debounceTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                await self.runPhoton(pending, id: id)
            }
        } else {
            online = .idle
        }

        emit()
    }

    public func setUserPos(_ position: CLLocationCoordinate2D?) {
        userPos = position
        // Nur das Offline-Ranking haengt an der Position — Photon bleibt gueltig.
        recomputeOffline()
        emit()
    }

    /// Schreibt den Treffer in die Recents, setzt die Suche zurueck, liefert ihn.
    @discardableResult
    public func selectResult(_ result: SearchResult) -> SearchResult {
        recents = recentsStore.add(result)
        clear()
        return result
    }

    public func clear() {
        query = ""
        cancelDebounce()
        requestID &+= 1
        resetOffline()
        online = .idle
        emit()
    }

    /// Nach einem Index-Ladefehler erneut versuchen.
    public func reloadIndex() {
        if case .loading = indexState { return }
        indexState = .unloaded
        ensureIndex()
        emit()
    }

    public func destroy() {
        cancelDebounce()
        requestID &+= 1
        offlineSeq &+= 1
        offlinePending = false
    }

    // MARK: - Intern

    private func cancelDebounce() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// Laedt den Index beim ERSTEN Bedarf (oder per `prewarm`), nie im Init.
    private func ensureIndex() {
        guard case .unloaded = indexState else { return }
        indexState = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                let count = try await self.offlineSource.load()
                self.indexState = .ready(count: count)
                self.recomputeOffline()
                self.emit()
            } catch {
                self.indexState = .error(message: "\(error)")
                self.logger.error("Ortsindex laedt nicht: \(String(describing: error), privacy: .public)")
                self.emit()
            }
        }
    }

    private func resetOffline() {
        offlineSeq &+= 1
        offlinePending = false
        offline = []
    }

    /// Fragt die Offline-Quelle. Die bisherigen Treffer bleiben waehrenddessen
    /// stehen (kein Flackern), `offlinePending` verhindert ein verfruehtes „leer".
    private func recomputeOffline() {
        guard case .ready = indexState,
              query.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.minQueryOffline else {
            resetOffline()
            return
        }

        offlineSeq &+= 1
        let seq = offlineSeq
        offlinePending = true
        let pending = query
        let position = userPos
        let limit = offlineLimit

        Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await self.offlineSource.search(pending, userPos: position, limit: limit)
                guard seq == self.offlineSeq else { return }
                self.offlinePending = false
                self.offline = results
                self.emit()
            } catch {
                guard seq == self.offlineSeq else { return }
                // Eine gescheiterte Suche heisst: der Index ist weg. Das ist ein
                // sichtbarer Zustand mit Retry, kein leeres Ergebnis.
                self.offlinePending = false
                self.offline = []
                self.indexState = .error(message: "\(error)")
                self.emit()
            }
        }
    }

    private func runPhoton(_ query: String, id: Int) async {
        let outcome = await photon.search(query)
        // Sequenz-Guard: langsame Antwort eines aelteren Query-Standes verwerfen.
        guard id == requestID else { return }

        switch outcome {
        case .ok(let results):
            online = .results(results)
        case .failure(.offline):
            online = .unavailableOffline
        case .failure(let reason):
            online = .error(reason)
        }
        emit()
    }

    private func buildState() -> SearchState {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).count < Self.minQueryOffline {
            return .idle(query: query, index: indexState, recents: recents)
        }

        let deduped = dedupedOnline()
        let onlineSettledEmpty: Bool
        switch deduped {
        case .idle: onlineSettledEmpty = true
        case .results(let results): onlineSettledEmpty = results.isEmpty
        default: onlineSettledEmpty = false
        }

        // Solange eine Quelle noch arbeitet, ist „leer" eine Luege — dann bleibt
        // es `results` mit leerer Offline-Sektion und sichtbarem Ladezustand.
        if offline.isEmpty, onlineSettledEmpty, indexState != .loading, !offlinePending {
            return .empty(query: query, index: indexState, online: deduped)
        }
        return .results(query: query, index: indexState, offline: offline, online: deduped)
    }

    private func dedupedOnline() -> OnlineState {
        guard case .results(let results) = online else { return online }
        return .results(Merge.dedupeAgainstOffline(offline, results))
    }

    private func emit() {
        state = buildState()
    }
}
