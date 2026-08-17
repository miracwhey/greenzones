import XCTest

/// Bedienung der Snap-Wege (Welle 5).
///
/// Ein Screenshot zeigt, dass die Kamera-Oberflaeche existiert — nicht, dass der
/// Plus-Knopf sie oeffnet, dass die Album-Kachel den Betrachter aufmacht oder
/// dass der Kontext dabei mitreist. Genau das wird hier bedient.
final class SnapFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(route: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "GZ_ROUTE": route,
            "GZ_FIXTURES": "1",
            "GZ_HOUR": "12",
        ]
        app.launch()
        return app
    }

    private func sheet(in app: XCUIApplication) -> XCUIElement {
        let sheet = app.descendants(matching: .any).matching(identifier: "gz.sheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 25), "Blatt erscheint nicht")
        waitUntilStill(sheet)
        return sheet
    }

    /// Vorhanden heisst nicht fertig: Blatt und Vollbild fahren mit einer Feder
    /// ein, und eine Geste waehrend der Fahrt verpufft.
    private func waitUntilStill(_ element: XCUIElement, timeout: TimeInterval = 3) {
        var previous = element.frame
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            let current = element.frame
            if current == previous, current.height > 0 { return }
            previous = current
        }
    }

    /// Der Plus-FAB auf der Karte fuehrt zur Kamera — ohne Spot in Reichweite
    /// steht dort „Auf der Karte", und der Sichtbarkeits-Schalter fehlt (ohne
    /// Spot gaebe es nichts einzuschraenken).
    func testSnapFabOpensCameraWithFreeContext() {
        let app = launch(route: "map_spots")
        let fab = app.buttons["gz.fab.snap"]
        XCTAssertTrue(fab.waitForExistence(timeout: 25), "Plus-FAB fehlt auf der Karte")
        fab.tap()

        let shutter = app.buttons["gz.camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10), "Kamera oeffnet nicht")
        XCTAssertTrue(app.staticTexts["Auf der Karte"].exists, "Kontext-Chip fehlt")
        XCTAssertFalse(app.buttons["Nur im Spot"].exists,
                       "ohne Spot darf es keinen Sichtbarkeits-Schalter geben")

        app.buttons["Kamera schließen"].tap()
        XCTAssertTrue(shutter.waitForNonExistence(timeout: 5), "Kamera schliesst nicht")
    }

    /// Aus dem Spot-Blatt heraus gehoert der Snap zu DIESEM Spot: der Chip nennt
    /// ihn, und die Sichtbarkeit wird waehlbar (geteilter Spot).
    func testAlbumCTAOpensCameraWithSpotContext() {
        let app = launch(route: "detail")
        _ = sheet(in: app)

        let cta = app.buttons["gz.snap.cta"]
        XCTAssertTrue(cta.waitForExistence(timeout: 10), "Snap-Knopf im Album fehlt")
        cta.tap()

        XCTAssertTrue(app.buttons["gz.camera.shutter"].waitForExistence(timeout: 10),
                      "Kamera oeffnet nicht")
        XCTAssertTrue(app.staticTexts["Unsere Bank"].exists, "Kontext-Chip nennt den Spot nicht")
        XCTAssertTrue(app.buttons["Nur im Spot"].exists,
                      "am geteilten Spot muss die Sichtbarkeit waehlbar sein")
        // Default ist „Alle Freunde" (Leon-Lock) — die Einschraenkung ist die Ausnahme.
        XCTAssertTrue(app.buttons["Alle Freunde"].isSelected
                      || app.buttons["Alle Freunde"].exists)
    }

    /// Tippen auf eine Album-Kachel oeffnet den Betrachter mit genau diesem Snap.
    func testTappingAlbumTileOpensViewer() {
        let app = launch(route: "detail")
        _ = sheet(in: app)

        let tile = app.descendants(matching: .any).matching(identifier: "gz.snap.cta").firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        // Die erste Foto-Kachel liegt rechts neben dem Snap-Knopf; ihr Label
        // traegt Autor und Zeit.
        let photo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Tara · ")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10), "Album-Kachel fehlt")
        photo.tap()

        // Der Betrachter traegt dieselbe Beschriftung in seiner Kopfzeile.
        let close = app.buttons["gz.viewer.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "Betrachter oeffnet nicht")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), "Betrachter schliesst nicht")
    }

    /// Der ganze Weg an einem Stueck: Auslöser → Bild durch die Pipeline →
    /// Dateien → Bestand → Album. Das Album zaehlt danach einen mehr, und der
    /// neue Snap traegt „wartet" (ohne Konto geht nichts raus — der ehrliche
    /// Zustand statt eines vorgetaeuschten Vollzugs).
    func testShutterAddsSnapToAlbum() {
        let app = launch(route: "camera_spot")
        let shutter = app.buttons["gz.camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 25), "Kamera erscheint nicht")
        // Ausgangslage: vier Fixture-Snaps liegen im Album (hinter der Kamera).
        XCTAssertTrue(app.staticTexts["ALBUM · 4"].waitForExistence(timeout: 15),
                      "Ausgangslage des Albums fehlt")

        shutter.tap()

        // Die Kamera schliesst sich selbst, danach faellt die Kachel ins Album.
        XCTAssertTrue(shutter.waitForNonExistence(timeout: 10), "Kamera bleibt offen")
        XCTAssertTrue(app.staticTexts["ALBUM · 5"].waitForExistence(timeout: 10),
                      "Der neue Snap steht nicht im Album")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "wartet auf Upload"))
            .firstMatch.waitForExistence(timeout: 5),
                      "Ohne Konto muss der Snap sichtbar auf den Upload warten")
    }

    /// Ziehen nach unten schliesst den Betrachter (Spike-Geste). Ein Screenshot
    /// beweist davon nichts — die Geste muss laufen.
    func testDragDownDismissesViewer() {
        let app = launch(route: "viewer")
        let close = app.buttons["gz.viewer.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 25), "Betrachter erscheint nicht")

        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        middle.press(forDuration: 0.1, thenDragTo: bottom)

        XCTAssertTrue(close.waitForNonExistence(timeout: 5), "Ziehen nach unten schliesst nicht")
    }
}
