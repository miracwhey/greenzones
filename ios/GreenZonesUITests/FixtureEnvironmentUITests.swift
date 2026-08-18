import XCTest

/// Der Fixture-Betrieb selbst ist ein Prüfling.
///
/// Anlass: Sobald die Standort-Erlaubnis im Simulator einmal erteilt war,
/// meldete CoreLocation von sich aus den Simulator-Standort (San Francisco) und
/// ueberschrieb den festen Fixture-Punkt — Karte, Distanzen und der Snap-Kontext
/// („Spot ≤ 30 m") standen danach in jedem Beweisbild falsch da, ohne dass
/// irgendetwas rot wurde. Diese Messung haelt den Punkt fest.
final class FixtureEnvironmentUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testFixtureLocationBeatsTheSimulatorPosition() {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "GZ_ROUTE": "detail",
            "GZ_FIXTURES": "1",
            "GZ_HOUR": "12",
        ]
        app.launch()

        // Der Fixture-Punkt liegt am Maschsee-Nordufer, der Spot 218 m entfernt.
        // Mit dem Simulator-Standort staende hier ein vierstelliger Kilometerwert.
        let distance = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "218 m von dir")).firstMatch
        XCTAssertTrue(distance.waitForExistence(timeout: 25),
                      "Die Distanz kommt nicht vom Fixture-Standort")
    }
}
