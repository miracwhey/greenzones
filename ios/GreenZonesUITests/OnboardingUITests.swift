import XCTest

/// Das Onboarding ist der einzige Bildschirm, den jeder genau einmal sieht — und
/// der einzige, bei dem ein Fehler nicht auffällt, weil ihn danach niemand mehr
/// aufruft. Beweisbilder zeigen die vier Zustände; ob man auch durchkommt und
/// danach in der App landet, zeigt nur eine Bedienung.
final class OnboardingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // Ohne Fixture-Punkt: der Fixture-Betrieb überspringt das Onboarding
        // absichtlich (Screenshots sollen die Karte zeigen). Hier ist es der
        // Prüfling, also muss es kommen.
        app.launchEnvironment = ["GZ_FIXTURES": "0", "GZ_HOUR": "12"]
        // „Noch nicht gesehen" über die Argument-Domain, die beim Lesen jede
        // gespeicherte Einstellung schlägt. Ohne das hinge der zweite Test am
        // ersten: der hat das Onboarding abgeschlossen, und danach kommt es nie
        // wieder — ein Test, der von der Reihenfolge abhängt, misst die
        // Reihenfolge.
        app.launchArguments = ["-gz_onboarded_v2", "NO"]
        app.launch()
        return app
    }

    func testFourStepsLeadIntoTheApp() {
        let app = launch()
        let primary = app.buttons["gz.onboarding.primary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 25), "Das Onboarding kommt nicht")

        // Schritt 1 trägt die Standortfrage, danach heißt der Knopf „Weiter“ —
        // und im letzten Schritt „Los geht's“. Vier Drücker, dann ist die App da.
        XCTAssertTrue(app.staticTexts["Wo du gerade stehst"].exists)
        primary.tap()
        XCTAssertTrue(app.staticTexts["Deine Daten bleiben deine"].waitForExistence(timeout: 5))
        primary.tap()
        XCTAssertTrue(app.staticTexts["Orte, die euch gehören"].waitForExistence(timeout: 5))
        primary.tap()
        XCTAssertTrue(app.staticTexts["Bilder bleiben im Kreis"].waitForExistence(timeout: 5))
        primary.tap()

        // Danach die Karte: die Statusleiste unten gehört keinem anderen
        // Bildschirm. Der Standort-Dialog des Systems kann davorstehen — er ist
        // nicht Teil der App-Hierarchie und blockiert diese Abfrage nicht.
        XCTAssertFalse(app.staticTexts["Bilder bleiben im Kreis"].waitForExistence(timeout: 3),
                       "Das Onboarding steht nach dem letzten Schritt noch")
    }

    /// Die Zwischenschritte dürfen nichts anfangen, was den Bildschirm belegt.
    /// Vorher fragte der Sync die Mitteilungs-Erlaubnis, sobald ein Freund im
    /// Bestand lag — nach dem v1-Import ist das beim allerersten Start der Fall,
    /// und der Systemdialog stand über dem Text, der ihn begründen soll.
    func testNoSystemDialogInterruptsTheSteps() {
        let app = launch()
        let primary = app.buttons["gz.onboarding.primary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 25))

        primary.tap()
        XCTAssertTrue(app.staticTexts["Deine Daten bleiben deine"].waitForExistence(timeout: 5))

        // Systemdialoge liegen in `springboard`, nicht in der App. Ein
        // Mitteilungs-Dialog wäre genau hier zu sehen.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let notificationAlert = springboard.alerts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Mitteilungen")).firstMatch
        XCTAssertFalse(notificationAlert.exists,
                       "Ein Systemdialog steht über dem Onboarding")
    }
}
