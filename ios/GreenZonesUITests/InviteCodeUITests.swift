import XCTest

/// Freunde per Code (`mockup/qr.html`): der Einladende zeigt, der Beitretende
/// scannt. Bedient wird der echte Weg — Einstiege im Freunde-Blatt, der
/// Profil-Schritt davor, der Code-Schritt, und die ehrlichen Ausgaenge des
/// Scanners (fremder Code, kein Konto).
final class InviteCodeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(route: String, extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "GZ_ROUTE": route,
            "GZ_FIXTURES": "1",
            "GZ_HOUR": "12",
        ].merging(extra) { _, new in new }
        app.launch()
        return app
    }

    /// Beide Wege stehen im Freunde-Blatt, und der Scan-Weg fuehrt wirklich in
    /// den Scanner — und aus ihm zurueck ins Blatt.
    func testFriendsSheetOffersBothWays() {
        let app = launch(route: "friends")

        let add = app.buttons["Freund hinzufügen"]
        XCTAssertTrue(add.waitForExistence(timeout: 25), "Freund-hinzufügen-Knopf fehlt")
        let scan = app.buttons["gz.friends.scan"]
        XCTAssertTrue(scan.exists, "Scan-Zeile fehlt")

        scan.tap()
        let close = app.buttons["gz.scanner.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "Scanner oeffnet nicht")

        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), "Scanner schliesst nicht")
        XCTAssertTrue(scan.waitForExistence(timeout: 5),
                      "nach dem Scanner steht das Freunde-Blatt nicht mehr da")
    }

    /// Der Einladen-Weg: Profil-Schritt → Code-Schritt. Der Code entsteht im
    /// Fixture-Lauf ueber den echten Renderweg; „Link teilen" steht daneben.
    func testInviteFlowLeadsToCode() {
        let app = launch(route: "friends")

        let add = app.buttons["Freund hinzufügen"]
        XCTAssertTrue(add.waitForExistence(timeout: 25), "Freund-hinzufügen-Knopf fehlt")
        add.tap()

        // Profil-Schritt: das Fixture-Profil (Leon) ist gesetzt, der Weiter-Knopf aktiv.
        let proceed = app.buttons["Weiter — Code zeigen"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 10), "Profil-Schritt fehlt")
        proceed.tap()

        XCTAssertTrue(app.images["gz.invite.code"].waitForExistence(timeout: 10),
                      "Code-Bild fehlt")
        XCTAssertTrue(app.staticTexts["Du lädst ein als Leon"].waitForExistence(timeout: 5),
                      "Absender-Zeile fehlt")
        XCTAssertTrue(app.buttons["gz.invite.sharelink"].exists, "Link-teilen-Weg fehlt")

        // Schliessen fuehrt zur Liste zurueck, nicht aus dem Blatt.
        app.buttons["Schließen"].firstMatch.tap()
        XCTAssertTrue(app.buttons["gz.friends.scan"].waitForExistence(timeout: 5),
                      "Schliessen fuehrt nicht zur Freundesliste zurueck")
    }

    /// Ohne Cloud endet der Code-Schritt ehrlich: Meldung + Weg zurueck.
    func testInviteCodeOfflineShowsRetry() {
        let app = launch(route: "invite_code_offline")

        let retry = app.buttons["gz.invite.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 25), "Fehlerzustand ohne Nochmal-Knopf")
        let message = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Ohne iCloud-Konto")).firstMatch
        XCTAssertTrue(message.exists, "Fehlertext fehlt oder erklaert nichts")
    }

    /// Ein fremder Code loest nichts aus — er wird benannt, mehr nicht.
    /// (Kontrollprobe zum Accept-Test darunter: gleicher Weg, andere Eingabe.)
    func testScannerRejectsForeignCode() {
        let app = launch(route: "scanner",
                         extra: ["GZ_SCAN_RESULT": "https://example.com/kein-invite"])

        let note = app.staticTexts["Kein GreenZones-Code"]
        XCTAssertTrue(note.waitForExistence(timeout: 25), "fremder Code wird nicht benannt")
        XCTAssertFalse(app.otherElements["gz.scanner.failed"].exists,
                       "fremder Code darf keinen Verbindungsfehler ausloesen")
    }

    /// Ein gueltiger Code nimmt den ganzen Accept-Weg — und scheitert ohne
    /// Konto ehrlich, mit Meldung und „Nochmal versuchen" zurueck zum Scannen.
    func testScannerAcceptFailsHonestlyWithoutCloud() {
        let app = launch(route: "scanner",
                         extra: ["GZ_SCAN_RESULT": "https://www.icloud.com/share/0TestEinladung"])

        let message = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Ohne iCloud-Konto")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 25),
                      "Accept-Fehler erreicht die Oberflaeche nicht")

        let retry = app.buttons["gz.scanner.retry"]
        XCTAssertTrue(retry.exists, "kein Weg zurueck nach dem Fehlschlag")
        retry.tap()
        XCTAssertTrue(app.staticTexts["Richte die Kamera auf den Code deines Freundes."]
                          .waitForExistence(timeout: 5),
                      "nach Nochmal steht der Scanner nicht wieder auf Anfang")
    }
}
