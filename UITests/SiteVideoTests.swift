import XCTest

@MainActor
final class SiteVideoTests: XCTestCase {
    private var french: Bool { ProcessInfo.processInfo.environment["PLUME_SITE_VIDEO"] == "fr" }

    func testSiteVideo() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLUME_SITE_VIDEO"] != nil, "PLUME_SITE_VIDEO is not set")
        let app = XCUIApplication()
        let language = french ? ["-AppleLanguages", "(fr-FR)", "-AppleLocale", "fr_FR"]
                              : ["-AppleLanguages", "(en-US)", "-AppleLocale", "en_US"]
        app.launchArguments = language + DemoServer.signedIn(user: french ? "demo-fr" : "demo")
        app.launch()
        func cell(_ name: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label ==[cd] %@", name)).firstMatch
        }
        let photos = cell("Photos"), space = cell(french ? "Espace" : "Space")
        XCTAssertTrue(photos.waitForExistence(timeout: 40))
        Thread.sleep(forTimeInterval: 4)
        print("VIDEO-START")
        Thread.sleep(forTimeInterval: 1.3)
        photos.tap()
        XCTAssertTrue(space.waitForExistence(timeout: 10))
        space.tap()
        Thread.sleep(forTimeInterval: 1.0)
        app.swipeUp(velocity: .slow)
        Thread.sleep(forTimeInterval: 0.4)
        let search = app.searchFields.firstMatch
        search.tap()
        for letter in french ? "electricite" : "resume" {
            search.typeText(String(letter))
            Thread.sleep(forTimeInterval: 0.08)
        }
        let found = cell(french ? "Facture d'électricité.pdf" : "Résumé 2026.pdf")
        XCTAssertTrue(found.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 0.8)
        found.tap()
        Thread.sleep(forTimeInterval: 2.6)
        print("VIDEO-END")
    }
}
