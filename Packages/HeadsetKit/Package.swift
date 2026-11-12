// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HeadsetKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GaiaProtocol", targets: ["GaiaProtocol"]),
        .library(name: "HeadsetCore", targets: ["HeadsetCore"]),
        .library(name: "HeadsetBluetooth", targets: ["HeadsetBluetooth"]),
        .library(name: "HeadsetSimulator", targets: ["HeadsetSimulator"]),
        .library(name: "SennseiCore", targets: ["SennseiCore"]),
        .library(name: "RemoteProtocol", targets: ["RemoteProtocol"]),
        .library(name: "SennseiControl", targets: ["SennseiControl"]),
        .executable(name: "sennsei", targets: ["SennseiCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "2.4.0"),
    ],
    targets: [
        .target(name: "GaiaProtocol"),
        .testTarget(name: "GaiaProtocolTests", dependencies: ["GaiaProtocol"]),
        .target(name: "HeadsetCore", dependencies: ["GaiaProtocol"]),
        .testTarget(
            name: "HeadsetCoreTests",
            dependencies: ["HeadsetCore", "GaiaProtocol"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "HeadsetSessionTests", dependencies: ["HeadsetCore", "HeadsetSimulator", "GaiaProtocol"]),
        .target(name: "HeadsetSimulator", dependencies: ["HeadsetCore", "GaiaProtocol"]),
        .testTarget(
            name: "HeadsetSimulatorTests",
            dependencies: ["HeadsetSimulator", "HeadsetCore", "GaiaProtocol"],
            resources: [.copy("Fixtures")]
        ),
        .target(
            name: "HeadsetBluetooth",
            dependencies: ["HeadsetCore"],
            linkerSettings: [.linkedFramework("IOBluetooth")]
        ),
        .target(name: "RemoteProtocol"),
        .testTarget(name: "RemoteProtocolTests", dependencies: ["RemoteProtocol"]),
        .target(name: "SennseiControl", dependencies: ["RemoteProtocol"]),
        .testTarget(name: "SennseiControlTests", dependencies: ["SennseiControl", "RemoteProtocol"]),
        .target(name: "SennseiCore", dependencies: ["HeadsetCore", "RemoteProtocol"], resources: [.process("Resources")]),
        .testTarget(
            name: "SennseiCoreTests",
            dependencies: ["SennseiCore", "HeadsetSimulator", "HeadsetCore", "GaiaProtocol", "RemoteProtocol"]
        ),
        .executableTarget(
            name: "SennseiApp",
            dependencies: [
                "SennseiCore", "SennseiControl", "RemoteProtocol", "HeadsetBluetooth", "HeadsetSimulator", "HeadsetCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ]
        ),
        .target(name: "SennseiCLICore", dependencies: ["RemoteProtocol", "SennseiControl"]),
        .executableTarget(name: "SennseiCLI", dependencies: ["SennseiCLICore"]),
        .testTarget(name: "SennseiCLITests", dependencies: ["SennseiCLICore", "RemoteProtocol", "SennseiControl"]),
        .executableTarget(name: "SennseiProbe", dependencies: ["HeadsetCore", "HeadsetBluetooth"]),
        .testTarget(name: "HeadsetBluetoothTests", dependencies: ["HeadsetBluetooth", "HeadsetCore"]),
    ]
)
