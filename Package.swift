// swift-tools-version:5.9
import PackageDescription

// 平台无关的核心逻辑（配置、决策状态机、SRun 协议、探测）放在 CampusNetCore，
// 可在任意 Swift 工具链（含 Linux CI）上执行单元测试。
// 菜单栏 App（SwiftUI + CoreWLAN + IOKit）只在 macOS 上参与构建。
var products: [Product] = [
    .library(name: "CampusNetCore", targets: ["CampusNetCore"])
]

var targets: [Target] = [
    .target(
        name: "CampusNetCore",
        path: "Sources/CampusNetCore"
    ),
    .testTarget(
        name: "CampusNetCoreTests",
        dependencies: ["CampusNetCore"],
        path: "Tests/CampusNetCoreTests"
    )
]

#if os(macOS)
products.append(.executable(name: "CampusNetPilot", targets: ["CampusNetPilot"]))
targets.append(
    .executableTarget(
        name: "CampusNetPilot",
        dependencies: ["CampusNetCore"],
        path: "Sources/CampusNetPilot",
        swiftSettings: [
            // 使用 @main 的 SwiftUI App 入口，需要按库模式解析（无 main.swift）。
            .unsafeFlags(["-parse-as-library"])
        ],
        linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("SwiftUI"),
            .linkedFramework("CoreWLAN"),
            .linkedFramework("CoreLocation"),
            .linkedFramework("IOKit"),
            .linkedFramework("Security")
        ]
    )
)
#endif

let package = Package(
    name: "CampusNetPilot",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
