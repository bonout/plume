// swift-tools-version: 6.0
import PackageDescription

// Everything the apps and their extensions share: the Nextcloud client
// (WebDAV, OCS, Login Flow v2), the local metadata store, local copies of
// files, the outbox of pending uploads (PlumeKit), and the few SwiftUI views
// used by both the apps and the share extension (PlumeUI).
let package = Package(
    name: "PlumeKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PlumeKit", targets: ["PlumeKit"]),
        .library(name: "PlumeUI", targets: ["PlumeUI"]),
    ],
    targets: [
        .target(name: "PlumeKit", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "PlumeUI", dependencies: ["PlumeKit"]),
        .testTarget(name: "PlumeKitTests", dependencies: ["PlumeKit"]),
    ]
)
