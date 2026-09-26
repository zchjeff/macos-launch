// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppBox",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppBoxCore", targets: ["AppBoxCore"]),
        .executable(name: "AppBox", targets: ["AppBox"]),
    ],
    targets: [
        // 全部领域逻辑。刻意不依赖 AppKit，使测试不需要 UI 运行时。
        .target(name: "AppBoxCore"),
        .executableTarget(name: "AppBox", dependencies: ["AppBoxCore"]),
        .testTarget(name: "AppBoxCoreTests", dependencies: ["AppBoxCore"]),
    ]
)
