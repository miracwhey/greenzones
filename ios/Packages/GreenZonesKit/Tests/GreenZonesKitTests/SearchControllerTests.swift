import CoreLocation
import Foundation
import Testing
@testable import GreenZonesKit

/// Kern-Port von `client/src/lib/search/__tests__/controller.test.ts`:
/// Sequenz-Guards, Mindestlängen, AND→OR über die echte Fixture,
/// alle Störungs-States und die Recents-Sektion.
@Suite("SearchController — Zustandsmaschine")
@MainActor
struct SearchControllerTests {
    private func manualHarness() throws -> (SearchController, ManualOffline, ManualPhoton) {
        let offline = ManualOffline()
        let photon = ManualPhoton()
        let controller = SearchController(offline: offline, photon: photon,
                                          recents: RecentsStore(database: try makeSearchDatabase()))
        return (controller, offline, photon)
    }

    private func fixtureHarness() async throws -> (SearchController, ManualPhoton, RecentsStore) {
        let index = PlacesIndex(url: try SearchFixture.makeDatabase())
        let photon = ManualPhoton()
        let recents = RecentsStore(database: try makeSearchDatabase())
        let controller = SearchController(offline: index, photon: photon, recents: recents)
        return (controller, photon, recents)
    }

    // MARK: - Konstanten

    @Test("Konstanten stehen wie in v1")
    func constants() {
        #expect(SearchController.minQueryOffline == 2)
        #expect(SearchController.minQueryOnline == 3)
        #expect(SearchController.offlineLimit == 6)
    }

    // MARK: - Index-Lazy-Load

    @Test("lädt den Index NICHT beim Konstruieren")
    func lazyLoad() async throws {
        let (controller, offline, _) = try manualHarness()
        #expect(await offline.loads == 0)
        #expect(controller.state == .idle(query: "", index: .unloaded, recents: []))
    }

    @Test("lädt beim ersten Bedarf und genau einmal")
    func loadsOnce() async throws {
        let (controller, offline, _) = try manualHarness()
        controller.setQuery("h")
        #expect(await offline.loads == 0)

        controller.setQuery("ha")
        try await TestWait.until("Index wird geladen") { await offline.loads == 1 }
        #expect(controller.state.index == .loading)

        await offline.settleLoad(42)
        try await TestWait.until("Index bereit") { controller.state.index == .ready(count: 42) }

        controller.setQuery("han")
        controller.setQuery("hann")
        await TestWait.settle()
        #expect(await offline.loads == 1)
    }

    @Test("Ladefehler ist ein sichtbarer Zustand, kein stilles Nichts")
    func loadFailure() async throws {
        let (controller, offline, _) = try manualHarness()
        controller.setQuery("hannover")
        try await TestWait.until("Ladeversuch") { await offline.loads == 1 }
        await offline.failLoad(LocalizedStringError("places.sqlite: weg"))
        try await TestWait.until("Fehlerzustand") {
            if case .error = controller.state.index { return true }
            return false
        }
    }

    @Test("reloadIndex versucht es erneut")
    func reloadIndex() async throws {
        let (controller, offline, _) = try manualHarness()
        controller.setQuery("hannover")
        try await TestWait.until("erster Versuch") { await offline.loads == 1 }
        await offline.failLoad(LocalizedStringError("weg"))
        try await TestWait.until("Fehlerzustand") {
            if case .error = controller.state.index { return true }
            return false
        }

        controller.reloadIndex()
        try await TestWait.until("zweiter Versuch") { await offline.loads == 2 }
        await offline.settleLoad(16)
        try await TestWait.until("bereit") { controller.state.index == .ready(count: 16) }
    }

    // MARK: - Mindestlängen

    @Test("unter 2 Zeichen: idle, keine Quelle wird angefasst")
    func belowMinimum() async throws {
        let (controller, offline, photon) = try manualHarness()
        controller.setQuery("h")
        await TestWait.settle()
        if case .idle = controller.state {} else { Issue.record("erwartet: idle") }
        #expect(await offline.loads == 0)
        #expect(await photon.calls.isEmpty)
    }

    @Test("2 Zeichen: offline ja, online idle")
    func twoCharacters() async throws {
        let (controller, photon, _) = try await fixtureHarness()
        controller.setQuery("ha")
        try await TestWait.until("Offline-Treffer") { !controller.state.offlineResults.isEmpty }
        await TestWait.settle()
        #expect(controller.state.online == .idle)
        #expect(await photon.calls.isEmpty)
    }

    @Test("3 Zeichen: online wird ANGEBOTEN, nicht angefragt")
    func threeCharacters() async throws {
        let (controller, photon, _) = try await fixtureHarness()
        controller.setQuery("han")
        await TestWait.settle()
        #expect(controller.state.online == .offerable)
        #expect(await photon.calls.isEmpty)
    }

    // MARK: - Der fremde Dienst wird nur auf Ansage gefragt

    /// Die Kernzusage: Tippen erreicht niemanden im Netz. Vorher ging ab drei
    /// Zeichen jedes Praefix als eigene Anfrage an einen fremden Geocoder.
    @Test("keine Tippfolge, egal wie lang, erzeugt einen Photon-Aufruf")
    func typingNeverCallsPhoton() async throws {
        let (controller, photon, _) = try await fixtureHarness()
        for prefix in ["han", "hann", "hannov", "hannover", "hannover ha"] {
            controller.setQuery(prefix)
        }
        await TestWait.settle()
        #expect(await photon.calls.isEmpty)
        #expect(controller.state.online == .offerable)
    }

    @Test("der Knopf fragt genau einmal und mit dem aktuellen Text")
    func explicitSearchAsksOnce() async throws {
        let (controller, photon, _) = try await fixtureHarness()
        controller.setQuery("han")
        controller.setQuery("hannov")
        controller.searchOnline()
        try await TestWait.until("ein Aufruf") { await photon.calls == ["hannov"] }
        await TestWait.settle()
        #expect(await photon.calls == ["hannov"])
    }

    @Test("zu kurzer Text: der Knopf tut nichts")
    func explicitSearchNeedsEnoughText() async throws {
        let (controller, photon, _) = try await fixtureHarness()
        controller.setQuery("ha")
        controller.searchOnline()
        await TestWait.settle()
        #expect(await photon.calls.isEmpty)
    }

    @Test("während des Wartens ist der Online-Zustand 'loading'")
    func loadingWhileWaiting() async throws {
        let (controller, _, _) = try await fixtureHarness()
        controller.setQuery("hannover")
        controller.searchOnline()
        #expect(controller.state.online == .loading)
    }

    // Ohne Debounce ist die Anfrage nach dem Druck sofort unterwegs — „stoppen"
    // heisst jetzt: ihre Antwort zaehlt nicht mehr.
    @Test("clear entwertet die laufende Anfrage")
    func clearVoidsPending() async throws {
        let (controller, photon, _) = try await fixtureHarness()
        controller.setQuery("hannover")
        controller.searchOnline()
        try await TestWait.until("Aufruf") { await photon.calls.count == 1 }
        controller.clear()
        await photon.settle(0, .ok([SearchFixture.result("Zu spaet")]))
        await TestWait.settle()
        if case .idle = controller.state {} else { Issue.record("erwartet: idle") }
    }

    @Test("destroy entwertet die laufende Anfrage")
    func destroyVoidsPending() async throws {
        let (controller, photon, _) = try await fixtureHarness()
        controller.setQuery("hannover")
        controller.searchOnline()
        try await TestWait.until("Aufruf") { await photon.calls.count == 1 }
        controller.destroy()
        await photon.settle(0, .ok([SearchFixture.result("Zu spaet")]))
        await TestWait.settle()
        #expect(controller.state.online != .results([SearchFixture.result("Zu spaet")]))
    }

    // MARK: - Sequenz-Guards

    @Test("verwirft die langsame ALTE Photon-Antwort, die nach der neuen eintrifft")
    func photonSequenceGuard() async throws {
        let (controller, photon, _) = try await fixtureHarness()
        let fresh = SearchResult(name: "Lange Laube", detail: "30449, Hannover, Niedersachsen",
                                 lng: 9.735, lat: 52.375, source: .photon)
        let stale = SearchResult(name: "VERALTET", detail: "", lng: 1, lat: 1, source: .photon)

        controller.setQuery("lange")
        controller.searchOnline()
        try await TestWait.until("erster Aufruf") { await photon.calls == ["lange"] }
        controller.setQuery("lange laube")
        controller.searchOnline()
        try await TestWait.until("zweiter Aufruf") { await photon.calls.count == 2 }

        // Neue Antwort zuerst …
        await photon.settle(1, .ok([fresh]))
        try await TestWait.until("neue Antwort steht") { controller.state.online == .results([fresh]) }

        // … dann trudelt die alte ein und darf nichts überschreiben.
        await photon.settle(0, .ok([stale]))
        await TestWait.settle()
        #expect(controller.state.online == .results([fresh]))
    }

    @Test("verwirft auch einen alten FEHLER")
    func staleErrorIgnored() async throws {
        let (controller, photon, _) = try await fixtureHarness()
        let fresh = SearchResult(name: "Lange Laube", detail: "30449, Hannover, Niedersachsen",
                                 lng: 9.735, lat: 52.375, source: .photon)
        controller.setQuery("lange")
        controller.searchOnline()
        try await TestWait.until("erster Aufruf") { await photon.calls.count == 1 }
        controller.setQuery("lange laube")
        controller.searchOnline()
        try await TestWait.until("zweiter Aufruf") { await photon.calls.count == 2 }

        await photon.settle(1, .ok([fresh]))
        try await TestWait.until("neue Antwort steht") { controller.state.online == .results([fresh]) }
        await photon.settle(0, .failure(.server))
        await TestWait.settle()
        #expect(controller.state.online == .results([fresh]))
    }

    @Test("verwirft die langsame ALTE Offline-Antwort")
    func offlineSequenceGuard() async throws {
        let (controller, offline, _) = try manualHarness()
        controller.prewarm()
        try await TestWait.until("Ladeversuch") { await offline.loads == 1 }
        await offline.settleLoad(3)
        try await TestWait.until("bereit") { controller.state.index == .ready(count: 3) }

        controller.setQuery("li")
        controller.setQuery("lin")
        try await TestWait.until("zwei Suchen") { await offline.searches == ["li", "lin"] }

        await offline.settleSearch(1, [SearchFixture.result("Linden-Nord")])
        try await TestWait.until("neue Treffer") {
            controller.state.offlineResults.map(\.name) == ["Linden-Nord"]
        }
        await offline.settleSearch(0, [SearchFixture.result("VERALTET")])
        await TestWait.settle()
        #expect(controller.state.offlineResults.map(\.name) == ["Linden-Nord"])
    }

    @Test("nach setQuery unter der Mindestlänge zählt keine nachlaufende Antwort mehr")
    func lateAnswerAfterShortening() async throws {
        let (controller, offline, _) = try manualHarness()
        controller.prewarm()
        try await TestWait.until("Ladeversuch") { await offline.loads == 1 }
        await offline.settleLoad(3)
        try await TestWait.until("bereit") { controller.state.index == .ready(count: 3) }

        controller.setQuery("lin")
        try await TestWait.until("Suche läuft") { await offline.searches.count == 1 }
        controller.setQuery("l")
        await offline.settleSearch(0, [SearchFixture.result("Linden-Mitte")])
        await TestWait.settle()
        if case .idle = controller.state {} else { Issue.record("erwartet: idle") }
    }

    // MARK: - Störungen sind sichtbar

    @Test("timeout und server landen in online.error")
    func visibleErrors() async throws {
        for reason in [PhotonErrorKind.timeout, .server] {
            let (controller, photon, _) = try await fixtureHarness()
            controller.setQuery("lange laube")
            controller.searchOnline()
            try await TestWait.until("Aufruf") { await photon.calls.count == 1 }
            await photon.settle(0, .failure(reason))
            try await TestWait.until("Fehler sichtbar") { controller.state.online == .error(reason) }
        }
    }

    @Test("offline → 'unavailableOffline', Offline-Treffer bleiben stehen")
    func offlineState() async throws {
        let (controller, photon, _) = try await fixtureHarness()
        controller.setQuery("hannover")
        controller.searchOnline()
        try await TestWait.until("Aufruf") { await photon.calls.count == 1 }
        await photon.settle(0, .failure(.offline))
        try await TestWait.until("offline sichtbar") {
            controller.state.online == .unavailableOffline
        }
        #expect(controller.state.offlineResults.map(\.name).contains("Hannover"))
    }

    @Test("Online-Fehler bei leerer Offline-Sektion ist NICHT 'empty'")
    func errorIsNotEmpty() async throws {
        let (controller, photon, _) = try await fixtureHarness()
        controller.setQuery("xyzzyq")
        controller.searchOnline()
        try await TestWait.until("Aufruf") { await photon.calls.count == 1 }
        await photon.settle(0, .failure(.timeout))
        try await TestWait.until("Fehler sichtbar") { controller.state.online == .error(.timeout) }
        if case .results = controller.state {} else { Issue.record("erwartet: results") }
    }

    // MARK: - empty

    @Test("beide Quellen leer und abgeschlossen → empty")
    func empty() async throws {
        let (controller, photon, _) = try await fixtureHarness()
        controller.setQuery("xyzzyq")
        controller.searchOnline()
        try await TestWait.until("Aufruf") { await photon.calls.count == 1 }
        await photon.settle(0, .ok([]))
        try await TestWait.until("empty") {
            if case .empty = controller.state { return true }
            return false
        }
    }

    @Test("solange die Offline-Suche läuft, ist es NIE empty")
    func neverEmptyWhilePending() async throws {
        let (controller, offline, photon) = try manualHarness()
        controller.prewarm()
        try await TestWait.until("Ladeversuch") { await offline.loads == 1 }
        await offline.settleLoad(3)
        try await TestWait.until("bereit") { controller.state.index == .ready(count: 3) }

        controller.setQuery("xyzzyq")
        controller.searchOnline()
        try await TestWait.until("Photon gefragt") { await photon.calls.count == 1 }
        await photon.settle(0, .ok([]))
        await TestWait.settle()
        // Online ist abgeschlossen und leer — offline arbeitet noch.
        if case .results = controller.state {} else { Issue.record("erwartet: results") }

        await offline.settleSearch(0, [])
        try await TestWait.until("jetzt empty") {
            if case .empty = controller.state { return true }
            return false
        }
    }

    @Test("während der Index lädt, ist es NIE empty")
    func neverEmptyWhileLoading() async throws {
        let (controller, offline, _) = try manualHarness()
        controller.setQuery("xy")
        try await TestWait.until("Ladeversuch") { await offline.loads == 1 }
        if case .results = controller.state {} else { Issue.record("erwartet: results") }
        #expect(controller.state.index == .loading)
    }

    @Test("eine gescheiterte Offline-Suche ist ein sichtbarer Index-Fehler")
    func failedSearchIsIndexError() async throws {
        let (controller, offline, _) = try manualHarness()
        controller.setQuery("linden")
        try await TestWait.until("Ladeversuch") { await offline.loads == 1 }
        await offline.settleLoad(3)
        try await TestWait.until("Suche läuft") { await offline.searches.count == 1 }
        await offline.failSearch(0, LocalizedStringError("Ortsindex weg"))
        try await TestWait.until("Index-Fehler") {
            if case .error = controller.state.index { return true }
            return false
        }
        #expect(controller.state.offlineResults.isEmpty)
    }

    // MARK: - Merge, Position, Recents

    @Test("Online-Treffer, den der Offline-Index schon zeigt, verschwindet")
    func dedupe() async throws {
        let (controller, photon, _) = try await fixtureHarness()
        controller.setUserPos(SearchFixture.hannover)
        controller.setQuery("linden")
        try await TestWait.until("Offline-Treffer") {
            controller.state.offlineResults.map(\.name).contains("Linden-Mitte")
        }
        controller.searchOnline()
        try await TestWait.until("Aufruf") { await photon.calls.count == 1 }
        await photon.settle(0, .ok([
            SearchResult(name: "Linden-Mitte", detail: "30449, Hannover, Niedersachsen",
                         lng: 9.7218, lat: 52.3663, source: .photon),
            SearchResult(name: "Lindener Marktplatz", detail: "30449, Hannover, Niedersachsen",
                         lng: 9.7229, lat: 52.3661, source: .photon),
        ]))
        try await TestWait.until("Online-Sektion steht") {
            if case .results(let list) = controller.state.online { return !list.isEmpty }
            return false
        }
        guard case .results(let list) = controller.state.online else {
            Issue.record("erwartet: Online-Treffer"); return
        }
        #expect(list.map(\.name) == ["Lindener Marktplatz"])
    }

    @Test("setUserPos rankt die Offline-Treffer neu")
    func reranksOnPosition() async throws {
        let (controller, _, _) = try await fixtureHarness()
        controller.setQuery("linden")
        try await TestWait.until("Treffer ohne Position") { !controller.state.offlineResults.isEmpty }
        let withoutPosition = controller.state.offlineResults[0]
        #expect(!withoutPosition.detail.contains("Hannover"))

        controller.setUserPos(SearchFixture.hannover)
        try await TestWait.until("Treffer mit Position") {
            controller.state.offlineResults.first?.name == "Linden-Mitte"
        }

        controller.setUserPos(nil)
        try await TestWait.until("wieder ohne Position") {
            controller.state.offlineResults.first?.name == withoutPosition.name
        }
    }

    @Test("selectResult schreibt Recents, setzt zurück und liefert die Auswahl")
    func selectResult() async throws {
        let (controller, _, recents) = try await fixtureHarness()
        controller.setQuery("hannover")
        try await TestWait.until("Treffer") { !controller.state.offlineResults.isEmpty }

        let pick = controller.state.offlineResults[0]
        #expect(controller.selectResult(pick) == pick)
        #expect(controller.state == .idle(query: "", index: .ready(count: SearchFixture.places.count),
                                          recents: [pick]))
        #expect(recents.list() == [pick])
    }

    @Test("Recents überleben eine neue Controller-Instanz auf derselben DB")
    func recentsSurvive() async throws {
        let database = try makeSearchDatabase()
        let store = RecentsStore(database: database)
        let pick = SearchFixture.result("Hannover", "Stadt · Niedersachsen",
                                        lat: 52.3745, lng: 9.7386)
        store.add(pick)

        let fresh = SearchController(offline: ManualOffline(), photon: ManualPhoton(),
                                     recents: RecentsStore(database: database))
        #expect(fresh.state == .idle(query: "", index: .unloaded, recents: [pick]))
    }
}
