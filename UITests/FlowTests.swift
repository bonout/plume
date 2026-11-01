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
        app.launchArguments = ["-AppleLanguages", "(en-US)", "-AppleLocale", "en_US"] + arguments
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

    func testWebDAVSignInAndBrowse() throws {
        let address = ProcessInfo.processInfo.environment["PLUME_UITEST_WEBDAV"] ?? "http://127.0.0.1:8098"
        let folder = "UI \(UUID().uuidString.prefix(6))"
        let auth = "Basic " + Data("plume:plume-webdav-pass".utf8).base64EncodedString()
        func send(_ method: String, _ path: String, body: Data? = nil) {
            var request = URLRequest(url: URL(string: address)!.appending(path: path))
            request.httpMethod = method
            request.setValue(auth, forHTTPHeaderField: "Authorization")
            request.httpBody = body
            let done = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
            done.wait()
        }
        send("MKCOL", folder)
        send("PUT", folder + "/hello.txt", body: Data("hello".utf8))
        addTeardownBlock { send("DELETE", folder) }
        launch(["-PlumeResetAccount", "YES", "-PlumeServerField", address])
        XCTAssertTrue(app.buttons["WebDAV"].waitForExistence(timeout: 10))
        app.buttons["WebDAV"].tap()
        app.textFields["User name"].tap()
        app.textFields["User name"].typeText("plume")
        app.secureTextFields["Password"].tap()
        app.secureTextFields["Password"].typeText("plume-webdav-pass")
        app.buttons["Sign In"].tap()
        XCTAssertTrue(cell(folder).waitForExistence(timeout: 20))
        let notNow = app.buttons.matching(NSPredicate(format: "label IN %@", ["Not Now", "Later", "Plus tard", "Pas maintenant"])).firstMatch
        if notNow.waitForExistence(timeout: 3) { notNow.tap() }
        XCTAssertFalse(app.buttons["Deleted Files"].exists)
        cell(folder).tap()
        XCTAssertTrue(cell("hello.txt").waitForExistence(timeout: 10))
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

    func testSortByName() {
        launch(DemoServer.signedIn(["-PlumeInitialPath", "Documents"]))
        let cover = cell("Cover letter.pdf"), resume = cell("Résumé 2026.pdf")
        XCTAssertTrue(resume.waitForExistence(timeout: 20))
        XCTAssertLessThan(cover.frame.minY, resume.frame.minY)
        app.buttons["Sort"].firstMatch.tap()
        app.buttons["Z to A"].tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(cover.frame.minY, resume.frame.minY)
        app.buttons["Sort"].firstMatch.tap()
        app.buttons["A to Z"].tap()
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
        let inPopover = app.popovers.buttons["Sign Out"].firstMatch
        let confirm = inPopover.waitForExistence(timeout: 5) ? inPopover : app.sheets.buttons["Sign Out"].firstMatch
        confirm.tap()
        XCTAssertTrue(app.buttons["Sign In with Browser"].waitForExistence(timeout: 20))
    }
}
