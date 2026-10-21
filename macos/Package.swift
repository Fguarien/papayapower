// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PapayaPower",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PapayaPower", targets: ["PapayaPower"]),
        .executable(name: "papaya", targets: ["papaya"]),
    ],
    targets: [
        .target(
            name: "PapayaCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(name: "PapayaPower", dependencies: ["PapayaCore"]),
        .executableTarget(name: "papaya", dependencies: ["PapayaCore"]),
    ]
)
