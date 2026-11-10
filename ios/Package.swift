// swift-tools-version:6.2
import PackageDescription

// PAgentData is the SwiftData persistence layer — the §5 schema as `@Model`
// classes, plus the conversions to and from the `PAgentCore` value types.
//
// It is an SPM package rather than only Xcode-target source for one reason:
// **the schema needs runtime verification, and compilation cannot provide it.**
// A `@Model` class that compiles can still fail when `ModelContainer` tries to
// translate it — a `Codable` struct attribute SwiftData will not persist, a
// `#Predicate` it cannot turn into a query, an `inverse:` keypath that does not
// line up. All of those surface on container creation, not at compile time.
//
// SwiftData runs on macOS, so `swift test` catches them here. The Xcode app
// target consumes this same package.
let package = Package(
    name: "PAgentData",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "PAgentData", targets: ["PAgentData"])
    ],
    dependencies: [
        .package(path: "../core")
    ],
    targets: [
        .target(
            name: "PAgentData",
            dependencies: [.product(name: "PAgentCore", package: "core")],
            path: "PAgentData",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PAgentDataTests",
            dependencies: ["PAgentData", .product(name: "PAgentCore", package: "core")],
            path: "Tests/PAgentDataTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
