import XCTest

enum DemoServer: Sendable {
    static let address = ProcessInfo.processInfo.environment["PLUME_UITEST_SERVER"] ?? "http://127.0.0.1:8099"
    static let user = ProcessInfo.processInfo.environment["PLUME_UITEST_USER"] ?? "demo"
    static let password = ProcessInfo.processInfo.environment["PLUME_UITEST_PASSWORD"] ?? "plume-demo-pass"

    static func signedIn(_ extra: [String] = [], user: String = user) -> [String] {
        ["-PlumeResetAccount", "YES", "-PlumeTestServer", address, "-PlumeTestUser", user,
         "-PlumeTestPassword", password] + extra
    }
}

@MainActor
final class FlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ arguments: [String]) {
        app.launchArguments = arguments
        app.launch()
    }

    private func cell(_ name: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label ==[cd] %@", name)).firstMatch
    }

    func testSignInWithAppPassword() {
        launch(["-PlumeResetAccount", "YES", "-PlumeServerField", DemoServer.address])
        XCTAssertTrue(app.buttons["Sign In with Browser"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["What is Nextcloud?"].exists)
        app.buttons["Use an app password instead"].tap()
        let login = app.textFields["Login"]
        login.tap()
        login.typeText(DemoServer.user)
        let password = app.secureTextFields["App password"]
        password.tap()
        password.typeText(DemoServer.password)
        app.buttons["Sign In"].tap()
        XCTAssertTrue(cell("Documents").waitForExistence(timeout: 20))
    }

    func testWrongPasswordIsExplained() {
        launch(["-PlumeResetAccount", "YES", "-PlumeServerField", DemoServer.address])
        app.buttons["Use an app password instead"].tap()
        app.textFields["Login"].tap()
        app.textFields["Login"].typeText(DemoServer.user)
        app.secureTextFields["App password"].tap()
        app.secureTextFields["App password"].typeText("wrong")
        app.buttons["Sign In"].tap()
        let message = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Wrong login or app password'")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 20))
    }

    func testWhatIsNextcloud() {
        launch(["-PlumeResetAccount", "YES"])
        app.buttons["What is Nextcloud?"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["Find a Nextcloud provider"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
    }

    func testBrowseAndPreview() {
        launch(DemoServer.signedIn())
        XCTAssertTrue(cell("Documents").waitForExistence(timeout: 20))
        cell("Documents").tap()
        XCTAssertTrue(cell("Résumé 2026.pdf").waitForExistence(timeout: 10))
        cell("Résumé 2026.pdf").tap()
        XCTAssertTrue(app.otherElements["QLPreviewControllerView"].waitForExistence(timeout: 20)
                      || app.navigationBars["Résumé 2026"].waitForExistence(timeout: 5))
    }

    func testBigFolderOpens() {
        launch(DemoServer.signedIn())
        XCTAssertTrue(cell("Archive").waitForExistence(timeout: 20))
        cell("Archive").tap()
        cell("Scans 2015-2025").tap()
        XCTAssertTrue(cell("Scan 00001.pdf").waitForExistence(timeout: 30))
    }

    func testSearchAsYouType() {
        launch(DemoServer.signedIn())
        XCTAssertTrue(cell("Documents").waitForExistence(timeout: 20))
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("resume")
        XCTAssertTrue(cell("Résumé 2026.pdf").waitForExistence(timeout: 20))
    }

    func testSaveFromAnotherApp() {
        let name = "Shared \(Int(Date().timeIntervalSince1970)).txt"
        launch(DemoServer.signedIn(["-PlumeImportSample", name]))
        XCTAssertTrue(app.staticTexts["Save “\(name)”"].waitForExistence(timeout: 20))
        let target = app.staticTexts.matching(NSPredicate(format: "label == 'Documents'")).allElementsBoundByIndex
            .first { $0.isHittable }
        XCTAssertNotNil(target)
        target?.tap()
        XCTAssertTrue(app.navigationBars["Documents"].waitForExistence(timeout: 10))
        app.buttons["Save Here"].tap()
        cell("Documents").tap()
        XCTAssertTrue(cell(name).waitForExistence(timeout: 30))
    }

    func testAvailableOffline() {
        launch(DemoServer.signedIn())
        XCTAssertTrue(cell("Travel").waitForExistence(timeout: 20))
        cell("Travel").tap()
        let folder = cell("Iceland 2026")
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        folder.press(forDuration: 1.2)
        let pin = app.buttons["Make Available Offline"]
        if pin.waitForExistence(timeout: 5) {
            pin.tap()
        } else {
            app.buttons["Remove from Offline"].tap()
            folder.press(forDuration: 1.2)
            app.buttons["Make Available Offline"].tap()
        }
        XCTAssertTrue(app.images["Available offline"].waitForExistence(timeout: 20))
        folder.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Remove from Offline"].waitForExistence(timeout: 10))
        app.buttons["Remove from Offline"].tap()
    }

    func testSignOut() {
        launch(DemoServer.signedIn())
        XCTAssertTrue(cell("Documents").waitForExistence(timeout: 20))
        app.buttons["Settings"].tap()
        let signOut = app.buttons["Sign Out"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 10))
        signOut.tap()
        app.buttons["Sign Out"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Sign In with Browser"].waitForExistence(timeout: 20))
    }
}
