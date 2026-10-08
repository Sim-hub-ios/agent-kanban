// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentKanban",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "AgentKanban", targets: ["AgentKanban"]),
        .library(name: "AgentKanbanCore", targets: ["AgentKanbanCore"]),
        .library(name: "AgentKanbanExecutors", targets: ["AgentKanbanExecutors"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "AgentKanbanCore", dependencies: ["CSQLite"]),
        .target(name: "AgentKanbanExecutors", dependencies: ["AgentKanbanCore"]),
        .executableTarget(name: "AgentKanban", dependencies: ["AgentKanbanCore", "AgentKanbanExecutors"], resources: [.copy("Resources")]),
        .testTarget(name: "AgentKanbanCoreTests", dependencies: ["AgentKanbanCore"]),
        .testTarget(name: "AgentKanbanExecutorsTests", dependencies: ["AgentKanbanExecutors", "AgentKanbanCore"]),
        .testTarget(name: "AgentKanbanAppTests", dependencies: ["AgentKanban", "AgentKanbanCore", "AgentKanbanExecutors"])
    ]
)
