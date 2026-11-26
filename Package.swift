// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TunnelGuard",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "tunnelguard-check-profile", targets: ["CheckProfile"]),
        .executable(name: "TunnelGuardApp", targets: ["TunnelGuardApp"]),
        .executable(name: "TunnelGuardFilterProbe", targets: ["FilterProbe"]),
        .executable(name: "TunnelGuardLab", targets: ["LabHost"]),
        .executable(name: "tunnelguard-network-probe", targets: ["NetworkProbe"]),
    ],
    targets: [
        .target(name: "TunnelGuardCore"),
        .executableTarget(name: "CheckProfile", dependencies: ["TunnelGuardCore"]),
        .executableTarget(name: "TunnelGuardApp"),
        .executableTarget(name: "FilterProbe"),
        .executableTarget(name: "LabHost"),
        .executableTarget(name: "NetworkProbe"),
    ]
)
