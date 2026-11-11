// swift-tools-version:6.2
import PackageDescription

// A macOS app that runs the real `PlannerView`.
//
// ## Why this exists
//
// The SwiftUI layer had zero coverage and no way to get any. The simulator
// needs a runtime download measured in hours, and even then App Attest returns
// `invalidKey` there — so the screen could only ever render its failure path.
//
// But `PlannerView.swift` imports only SwiftUI, SwiftData, PAgentCore and
// PAgentNet, all of which build on macOS. The single iOS-only reference was
// `AppAttestTokenProvider`, now injected rather than named (see
// `PlannerModel.TokenProviderFactory`). So the **same source file** — not a
// copy, not a mock — compiles and runs here.
//
// ## What it can and cannot show
//
// Real: the view hierarchy, the streaming updates as deltas arrive, the usage
// panel, the §9.3 disclosure screen, and every error path.
//
// Substituted: the device token is signed with the deployment's own
// `JWT_SIGNING_KEY`, exactly as `proxy/scripts/verify-cache.mjs` does. That
// exercises the proxy's verification path and says nothing about attestation,
// which only a provisioned device can.
//
// Not present: `PAgentApp`, `NightlyMaintenance` (BackgroundTasks) and the
// Share Extension (UIKit). Those stay iOS-only; this harness provides its own
// entry point.
let package = Package(
    name: "PAgentPreview",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "../core")
    ],
    targets: [
        .executableTarget(
            name: "pagent-preview",
            dependencies: [
                .product(name: "PAgentCore", package: "core"),
                .product(name: "PAgentNet", package: "core"),
            ],
            path: "Sources/pagent-preview",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
