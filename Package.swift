// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pless",
    platforms: [.macOS(.v14)],
    targets: [
        // Minimales Test-Framework: CLT liefert weder XCTest noch Swift-Testing-Makros.
        .target(
            name: "MiniTest",
            path: "Sources/MiniTest"
        ),
        .target(
            name: "PlessCore",
            path: "Sources/PlessCore"
        ),
        .executableTarget(
            name: "Pless",
            dependencies: ["PlessCore"],
            path: "Sources/Pless"
        ),
        .executableTarget(
            name: "PlessTests",
            dependencies: ["PlessCore", "MiniTest"],
            path: "Tests/PlessTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
