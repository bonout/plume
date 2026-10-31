import XCTest

@MainActor
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    private struct Locale {
        let user: String
        let photos: String
        let search: String
        let found: String
        let offline: String
        let preview: String
        let sample: String
    }

    private var locale: Locale {
        let french = (Snapshot.deviceLanguage.hasPrefix("fr")) || ProcessInfo.processInfo.environment["PLUME_SHOTS_LOCALE"] == "fr"
        return french
            ? Locale(user: "demo-fr", photos: "Photos/Espace", search: "electricite", found: "Facture d'électricité.pdf",
                     offline: "Voyages/Islande 2026", preview: "Documents/CV 2026.pdf", sample: "Plan du jardin.jpg")
            : Locale(user: "demo", photos: "Photos/Space", search: "resume", found: "Résumé 2026.pdf",
                     offline: "Travel/Iceland 2026", preview: "Documents/Résumé 2026.pdf", sample: "Garden plan.jpg")
    }

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        setupSnapshot(app, waitForAnimations: true)
    }

    private func show(_ arguments: [String], waitFor text: String, seconds: Double = 4) {
        let snapshotArguments = app.launchArguments.filter { $0.hasPrefix("-FASTLANE") || $0.hasPrefix("-ui_testing") }
        app.terminate()
        app.launchArguments = Array(Set(snapshotArguments)) + languageArguments + arguments
        app.launch()
        _ = app.staticTexts[text].firstMatch.waitForExistence(timeout: 40)
        Thread.sleep(forTimeInterval: seconds)
    }

    private var languageArguments: [String] {
        guard let index = app.launchArguments.firstIndex(of: "-AppleLanguages"), index + 1 < app.launchArguments.count
        else { return [] }
        return ["-AppleLanguages", app.launchArguments[index + 1],
                "-AppleLocale", app.launchArguments.firstIndex(of: "-AppleLocale").map { app.launchArguments[$0 + 1] } ?? "en_US"]
    }

    private func signedIn(_ extra: [String]) -> [String] {
        DemoServer.signedIn(extra, user: locale.user)
    }

    func testScreenshots() {
        let locale = locale
        let photosName = String(locale.photos.split(separator: "/").last!)
        show(signedIn(["-PlumeInitialPath", locale.photos]), waitFor: photosName, seconds: 8)
        snapshot("01-browse")

        show(signedIn(["-PlumeSearch", locale.search]), waitFor: locale.found)
        snapshot("02-search")

        show(signedIn([]), waitFor: "Documents", seconds: 6)
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.activate()
        if files.tabBars.buttons.element(boundBy: 2).waitForExistence(timeout: 10) {
            files.tabBars.buttons.element(boundBy: 2).tap()
        }
        let plume = files.cells.containing(.staticText, identifier: "Plume").firstMatch
        if plume.waitForExistence(timeout: 15) {
            plume.tap()
            _ = files.staticTexts["Documents"].waitForExistence(timeout: 30)
            Thread.sleep(forTimeInterval: 4)
            snapshot("03-files-app")
        }
        files.terminate()

        let offlineName = String(locale.offline.split(separator: "/").last!)
        show(signedIn(["-PlumePin", locale.offline, "-PlumeInitialPath", locale.offline]), waitFor: offlineName, seconds: 10)
        snapshot("04-offline")

        let folder = String(locale.preview.split(separator: "/").first!)
        show(signedIn(["-PlumeInitialPath", folder, "-PlumePreview", locale.preview]), waitFor: folder, seconds: 10)
        snapshot("05-quick-look")

        show(signedIn(["-PlumeImportSample", locale.sample]), waitFor: "Documents", seconds: 6)
        snapshot("06-save-from-any-app")

        show(["-PlumeResetAccount", "YES", "-PlumeServerField", "cloud.example.com"], waitFor: "Plume", seconds: 3)
        snapshot("07-privacy")
    }
}
