// swift-tools-version:6.2
import PackageDescription

// Two targets, split by what they are allowed to touch.
//
// **PAgentCore** is *pure logic*: token budgeting, interest-graph decay,
// profile-card rendering, Claude request construction, SSE parsing, and the
// agent loop. No EventKit, CoreLocation, PhotoKit, HealthKit, SwiftUI, or
// network.
//
// That boundary is not architectural tidiness for its own sake — it is what
// lets the hardest-to-get-right logic (IMPLEMENTATION.md R8 byte stability,
// §6.1 token budgeting, §7.3 tool-result merging) be built and tested with
// `swift test`, which is how all of it was written before Xcode existed on
// this machine (§10 前置).
//
// **PAgentNet** adds the one thing that genuinely needs a network: talking to
// the proxy. It keeps the same discipline — the transport logic is tested
// against a stubbed byte streamer, and the `URLSession` call is a thin
// adapter at the edge — because retry and error-mapping bugs are exactly the
// kind that only show up against a server that is already misbehaving.
let package = Package(
    name: "PAgentCore",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "PAgentCore", targets: ["PAgentCore"]),
        .library(name: "PAgentNet", targets: ["PAgentNet"]),
    ],
    targets: [
        .target(
            name: "PAgentCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PAgentCoreTests",
            dependencies: ["PAgentCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "PAgentNet",
            dependencies: ["PAgentCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PAgentNetTests",
            dependencies: ["PAgentNet", "PAgentCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Prints the exact request body the app sends, for the live cache
        // check in `proxy/scripts/verify-cache.mjs`. A JSON fixture would keep
        // passing while the real request path broke the cache — see the note
        // at the top of its `main.swift`.
        .executableTarget(
            name: "pagent-emit-request",
            dependencies: ["PAgentCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Drives a real agent turn from the command line against a running
        // proxy. `AgentLoop` is protocol-injected, so this uses the shipping
        // `ProxyTransport`; only App Attest and the EventKit/MapKit tools are
        // substituted, and neither exists off-device anyway. The note at the
        // top of its `main.swift` says what that does and does not prove.
        .executableTarget(
            name: "pagent-chat",
            dependencies: ["PAgentCore", "PAgentNet"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
