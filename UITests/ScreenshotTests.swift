import XCTest
import UIKit

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

    private var french: Bool {
        Snapshot.deviceLanguage.hasPrefix("fr") || ProcessInfo.processInfo.environment["PLUME_SHOTS_LOCALE"] == "fr"
    }

    private var locale: Locale {
        french
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
        files.terminate()
        files.launchArguments = french ? ["-AppleLanguages", "(fr-FR)", "-AppleLocale", "fr_FR"]
                                       : ["-AppleLanguages", "(en-US)", "-AppleLocale", "en_US"]
        files.launch()
        let plume = files.staticTexts.matching(NSPredicate(format: "label == 'Plume'")).firstMatch
        for _ in 0..<5 where !(plume.waitForExistence(timeout: 3) && plume.isHittable) {
            let back = files.navigationBars.buttons.element(boundBy: 0)
            if back.exists && back.isHittable {
                back.tap()
            } else if files.tabBars.buttons.count > 2 {
                files.tabBars.buttons.element(boundBy: files.tabBars.buttons.count - 1).tap()
            }
        }
        if plume.exists && plume.isHittable {
            plume.tap()
            let turnOn = files.buttons.matching(NSPredicate(format: "label IN %@", ["Turn On", "Activer"])).firstMatch
            if turnOn.waitForExistence(timeout: 3) {
                turnOn.tap()
            }
            _ = files.staticTexts["Documents"].waitForExistence(timeout: 30)
            Thread.sleep(forTimeInterval: 4)
            snapshot("03-files-app")
        } else if UIDevice.current.userInterfaceIdiom == .phone {
            print(files.debugDescription)
            XCTFail("Plume location not found in Files")
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
