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

        // Seit dem 18.08. liegt das Sichern im Unterblatt „Karte & Daten" —
        // der Weg dorthin gehoert damit zur Zusage: ein Knopf, den niemand
        // findet, ist keiner.
        let manage = app.buttons["gz.info.manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 25),
                      "Das Info-Blatt zeigt keinen Weg zu „Karte & Daten“")
        manage.tap()

        let download = app.buttons["gz.info.offlineDownload"]
        XCTAssertTrue(download.waitForExistence(timeout: 10),
                      "Das Blatt „Karte & Daten“ bietet das Sichern nicht an")
        download.tap()

        // Der Fortschritt zählt Ressourcen, nicht Sekunden — sichtbar wird er,
        // sobald die ersten Kacheln da sind.
        let progress = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Lädt")).firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 30),
                      "Der Download meldet keinen Fortschritt. Sichtbar: "
                        + app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
    }

    /// Die ODbL-Nennung darf beim Entlasten des Blattes nicht mit ausziehen.
    ///
    /// Der gebündelte Kartenstil trägt kein `attribution`-Feld — was der
    /// MapLibre-Knopf zeigt, holt er aus der TileJSON von OpenFreeMap. Ohne
    /// Netz ist das erste Info-Blatt damit der einzige belegte Ort der Nennung,
    /// und ohne Netz soll die App seither ja gerade laufen.
    ///
    /// „ODbL" statt „OpenStreetMap" als Anker: der Name steht auch im Abschnitt
    /// „Kein Rechtsrat", der Test wäre dann grün, obwohl die Zeile fehlt.
    func testAttributionStaysOnTheFirstSheet() {
        let app = XCUIApplication()
        app.launchEnvironment = ["GZ_ROUTE": "info", "GZ_FIXTURES": "1", "GZ_HOUR": "12"]
        app.launch()

        let odbl = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "ODbL")).firstMatch
        XCTAssertTrue(odbl.waitForExistence(timeout: 25),
                      "Die ODbL-Nennung steht nicht im ersten Info-Blatt")
    }
}
