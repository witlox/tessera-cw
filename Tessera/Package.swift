// swift-tools-version: 5.9
// NOTE: Compiles in Xcode / SwiftPM with the GRDB dependency resolved.
// Not built in the content-generation sandbox (no Swift toolchain there).
import PackageDescription

let package = Package(
    name: "TesseraKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TesseraKit", targets: ["TesseraKit"])
    ],
    dependencies: [
        // Lightweight SQLite wrapper for reading the bundled, read-only corpus.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0")
    ],
    targets: [
        .target(
            name: "TesseraKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Resources/tessera.sqlite")]   // bundle the corpus
        ),
        .testTarget(name: "TesseraKitTests", dependencies: ["TesseraKit"])
    ]
)
