import XCTest

/// „Umgebung sichern" ist eine Zusage über einen Zustand, den man erst merkt,
/// wenn kein Netz mehr da ist — also genau dann, wenn niemand mehr etwas
/// reparieren kann. Der Test hält fest, dass der Knopf einen echten Download
/// startet.
///
/// NICHT geprüft (und nur am Gerät prüfbar): dass die Karte im Flugmodus
/// tatsächlich steht. Dafür müsste das Netz weg sein, ohne dass sich die
/// Adressen ändern — der Vorrat hängt an genau diesen Adressen.
final class OfflineMapUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testSavingTheAreaStartsARealDownload() {
        let app = XCUIApplication()
        // Fixture-Standort: ohne Mittelpunkt bietet das Blatt das Sichern gar
        // nicht erst an, und der Test prüfte dann nur seine eigene Kulisse.
        app.launchEnvironment = ["GZ_ROUTE": "info", "GZ_FIXTURES": "1", "GZ_HOUR": "12"]
        app.launch()

        let download = app.buttons["gz.info.offlineDownload"]
        XCTAssertTrue(download.waitForExistence(timeout: 25),
                      "Das Info-Blatt bietet das Sichern nicht an")
        download.tap()

        // Der Fortschritt zählt Ressourcen, nicht Sekunden — sichtbar wird er,
        // sobald die ersten Kacheln da sind.
        let progress = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Lädt")).firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 30),
                      "Der Download meldet keinen Fortschritt")
    }
}
