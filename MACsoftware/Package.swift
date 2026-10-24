// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HushlightMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "BridgeCore", targets: ["BridgeCore"]),
        .library(name: "WorkbenchKit", targets: ["WorkbenchKit"]),
        .executable(name: "HushlightMac", targets: ["HushlightMac"]),
        .executable(name: "agent-workbench-mcp", targets: ["AgentWorkbenchMCP"]),
        .executable(name: "hushlight-bridge", targets: ["HushlightBridgeCLI"])
    ],
    targets: [
        .target(name: "WorkbenchKit"),
        .target(
            name: "BridgeCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "HushlightMac",
            dependencies: ["BridgeCore", "WorkbenchKit"],
            resources: [.copy("Resources/NotesBridge.applescript"), .copy("Resources/MailScopeBridge.applescript"), .copy("Resources/MailDraftBridge.applescript")]
        ),
        .executableTarget(
            name: "HushlightBridgeCLI",
            dependencies: ["BridgeCore"]
        ),
        .testTarget(
            name: "HushlightMacTests",
            dependencies: ["HushlightMac", "BridgeCore", "WorkbenchKit", "AgentWorkbenchMCP"]
        ),
        .executableTarget(
            name: "AgentWorkbenchMCP",
            dependencies: ["WorkbenchKit"]
        ),
        .testTarget(
            name: "AgentWorkbenchMCPTests",
            dependencies: ["AgentWorkbenchMCP", "WorkbenchKit"]
        )
    ]
)
