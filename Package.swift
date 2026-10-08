// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MeteocatNative", defaultLocalization: "ca", platforms: [.macOS(.v14)], products: [
    .library(name: "MeteocatCore", targets: ["MeteocatCore"]),
    .executable(name: "Meteocat", targets: ["MeteocatApp"]),
    .executable(name: "FixtureImport", targets: ["FixtureImport"])
], targets: [
    .target(name: "MeteocatCore", resources: [.copy("Resources/Geography"), .copy("Resources/PreviewFixture")], linkerSettings: [.linkedLibrary("z")]),
    .executableTarget(name: "MeteocatApp", dependencies: ["MeteocatCore"], resources: [.process("Resources")]),
    .executableTarget(name: "FixtureImport", dependencies: ["MeteocatCore"]),
    .testTarget(name: "MeteocatAppTests", dependencies: ["MeteocatApp", "MeteocatCore"]),
    .testTarget(name: "MeteocatCoreTests", dependencies: ["MeteocatCore"], resources: [.copy("Fixtures")])
])
