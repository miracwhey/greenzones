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
        waitUntilStill(sheet)
        return sheet
    }

    /// Wartet, bis das Blatt steht.
    ///
    /// Vorhanden heisst nicht fertig: das Blatt faehrt mit einer Feder ein, und
    /// eine Wischgeste waehrend der Fahrt verpufft. Ohne diese Wartezeit ist der
    /// Wisch-Test zufaellig rot — gemessen wird die Ruhe, nicht geraten.
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

    /// Leons Beschwerde vom Geraet als Messung: „manchmal zu schwer
    /// wegzuwischen". Ein Finger, der 40 pt unter der Blattkante ansetzt,
    /// verfehlte den Griff und die Geste verpuffte; mit dem Trefferzuschlag
    /// greift sie.
    ///
    /// **Die 40 pt sind gemessen, nicht gewaehlt.** Bei 30 pt ist der Test auch
    /// mit `grabberHitSlop = 0` gruen — UIKit gibt jedem Ziel von sich aus etwas
    /// Rand, der sichtbare Griff (18 pt) trifft also weiter, als er aussieht.
    /// Eine Probe an dieser Stelle haette den Zuschlag bestaetigt, ohne ihn je
    /// zu beruehren. Bei 40 pt kippt sie: ohne Zuschlag rot, mit gruen — beides
    /// nachgestellt.
    func testSwipeJustBelowTheGrabberClosesIt() {
        let app = launch(route: "detail")
        let sheet = sheet(in: app)

        // Absolut ab Blattoberkante, nicht normalisiert: 40 pt sind 40 pt,
        // egal wie hoch das Blatt gerade ist.
        let belowGrabber = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 40))
        let below = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        belowGrabber.press(forDuration: 0.1, thenDragTo: below)

        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5),
                      "Wischen knapp unter dem Griff schliesst nicht")
    }

    // Der zweite Grund, warum es „zu schwer" war — die Schwelle war ein reines
    // Wegmass, ein kurzer schneller Wisch kam nicht weit genug —, ist hier
    // BEWUSST nicht geprueft: **XCUITest kann keinen schnellen Wisch erzeugen.**
    //
    // Gemessen, nicht vermutet. Bei `press(forDuration: 0.01, thenDragTo:,
    // withVelocity: .fast)` ueber 55 pt meldete die Geste `weg=29.0,
    // vorhersage=44.0` — die Vorhersage ist der Weg plus ein Nichts, es kommt
    // keine Geschwindigkeit an. Und beim langsamen Wisch ueber die volle Hoehe
    // stand `weg=258.3, vorhersage=230.8`: die Vorhersage faellt unter den Weg
    // zurueck, weil die Hand am Ende steht. Ein Test dagegen wuerde nicht die
    // Regel messen, sondern den Nachbau der Eingabe — und waere rot, obwohl
    // der Code stimmt.
    //
    // Damit ist die Geschwindigkeits-Schwelle **am Geraet zu pruefen**, nicht
    // hier. Die Konstruktion ist dieselbe wie im Betrachter, wo sie sich in
    // Leons Hand bereits bewaehrt hat.

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
