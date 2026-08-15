import XCTest

/// Bedienung des Blatts (`gzSheet`).
///
/// Die Sheets sind seit dem iOS-26-Umbau kein Systemsheet mehr: Tippen daneben,
/// Wischen am Griff und der kantenbuendige Sitz sind Eigenbau. Screenshots
/// zeigen davon nur das Aussehen — hier wird bedient.
final class BottomSheetUITests: XCTestCase {
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
        // Die Fixture-Route oeffnet das Blatt 2,2 s nach dem Start (die Karte
        // soll vorher stehen) — die Wartezeit deckt Start plus Verzoegerung.
        // Nicht ueber den Elementtyp suchen: das Blatt ist heute ein ScrollView,
        // morgen vielleicht nicht — der Bezeichner bleibt.
        let sheet = app.descendants(matching: .any).matching(identifier: "gz.sheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 25), "Blatt erscheint nicht")
        return sheet
    }

    /// Leons Beschwerde als Messung: das Systemsheet unter iOS 26 sitzt seitlich
    /// eingerueckt und ueber dem unteren Rand. Das Blatt muss beide Kanten
    /// beruehren, sonst ist der alte Look zurueck.
    func testSheetSitsFlushWithTheScreenEdges() {
        let app = launch(route: "detail")
        let frame = sheet(in: app).frame
        let screen = app.windows.firstMatch.frame

        XCTAssertEqual(frame.minX, screen.minX, accuracy: 0.5, "links nicht buendig")
        XCTAssertEqual(frame.maxX, screen.maxX, accuracy: 0.5, "rechts nicht buendig")
        XCTAssertEqual(frame.maxY, screen.maxY, accuracy: 0.5, "unten nicht buendig")
        XCTAssertLessThan(frame.height, screen.height * 0.9, "Blatt deckt den Bildschirm")
    }

    func testTapBesideTheSheetClosesIt() {
        let app = launch(route: "detail")
        let sheet = sheet(in: app)

        // Ueber dem Blatt, auf der verdunkelten Karte — unterhalb des Suchfelds,
        // sonst traefe der Tipp die Suche statt der Verdunkelung.
        let above = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30))
        above.tap()

        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Tippen daneben schliesst nicht")
    }

    func testSwipeDownOnTheGrabberClosesIt() {
        let app = launch(route: "detail")
        let sheet = sheet(in: app)

        // Der Griff sitzt in den obersten Punkten des Blatts.
        let grabber = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
        let below = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        grabber.press(forDuration: 0.1, thenDragTo: below)

        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Wischen am Griff schliesst nicht")
    }

    /// Gegenprobe zum Wischen: auf dem Inhalt darf die Geste NICHT schliessen,
    /// sonst waere ein langes Blatt (Profil, Spot markieren) nicht scrollbar.
    func testSwipeOnTheContentKeepsTheSheetOpen() {
        let app = launch(route: "profile")
        let sheet = sheet(in: app)

        let middle = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let below = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        middle.press(forDuration: 0.1, thenDragTo: below)

        XCTAssertTrue(sheet.exists, "Wischen auf dem Inhalt hat das Blatt geschlossen")
    }
}
