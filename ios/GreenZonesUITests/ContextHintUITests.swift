import XCTest

/// Die In-Kontext-Hinweise sind ein Versprechen mit zwei Hälften: sie stehen
/// beim ersten Mal da — und danach nie wieder. Die zweite Hälfte ist die, die
/// still kaputtgehen kann, ohne dass es jemandem auffällt: ein Hinweis, der
/// bleibt, wird zur Möblierung.
///
/// Geprüft wird die Wiederholung INNERHALB eines Laufs. Über einen Neustart
/// hinweg geht es hier nicht: Fixture-Läufe arbeiten auf einer Datenbank im
/// Speicher (`AppModel`), auf der Platte landet nichts. Dass der Vermerk das
/// Neuöffnen der Datenbank überlebt, hält der Kit-Test `seenHints` fest — die
/// beiden Hälften zusammen decken die Zusage ab.
final class ContextHintUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTheHintShowsOnceAndThenNeverAgain() {
        let app = XCUIApplication()
        app.launchEnvironment = ["GZ_ROUTE": "friends", "GZ_FIXTURES": "1", "GZ_HOUR": "12",
                                 "GZ_HINTS_RESET": "1"]
        app.launch()

        let hint = app.staticTexts["gz.hint.friends"]
        XCTAssertTrue(hint.waitForExistence(timeout: 25),
                      "Der Hinweis im Freunde-Blatt fehlt beim ersten Öffnen")

        app.buttons["Schließen"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Freunde"].waitForExistence(timeout: 10),
                      "Nach dem Schließen ist die Karte nicht da")
        app.buttons["Freunde"].tap()

        // Warten, bis das Blatt wirklich wieder steht — sonst prüft die
        // Abwesenheit nur, dass noch nichts gezeichnet ist.
        XCTAssertTrue(app.staticTexts["Freunde"].waitForExistence(timeout: 10),
                      "Das Freunde-Blatt öffnet nicht erneut")
        XCTAssertFalse(hint.exists, "Der Hinweis steht beim zweiten Mal noch da")
    }
}
