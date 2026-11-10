import Foundation

/// What the user is asking for, as classified on device.
///
/// Classification runs on the 4096-token on-device model (§7.1) — a single
/// sentence fits comfortably, and keeping it local means the router costs
/// nothing and works offline.
public enum Intent: String, Sendable, Codable, CaseIterable, Hashable {
    /// Tag extraction, parsing shared content. Never leaves the device.
    case signalExtraction
    /// "我周六几点有空" — answerable from local tools alone.
    case factualQuery
    /// "周六下午安排点事" — one day, few constraints.
    case singleDayPlanning
    /// "下周末两天，想去看展+徒步，别太赶" — multi-day, multi-constraint.
    case complexPlanning
}

/// Where a request is sent.
public enum Route: Sendable, Hashable {
    /// Foundation Models, on device. Free, offline, ~85% of calls (§4.3).
    case onDevice
    /// On-device model plus local tool execution, still no network.
    case onDeviceWithTools
    case cloud(DeepSeekModel)
}

/// Whether the on-device path is usable right now.
///
/// Mirrors `SystemLanguageModel.availability` plus the health signals R2 and
/// R3 ask for. The device path is an *optimisation*, never a requirement:
/// Apple Intelligence needs an iPhone 15 Pro or better, which rules out most
/// of the installed base, so every on-device route must have a cloud twin.
public struct OnDeviceAvailability: Sendable, Hashable {
    public static let available = OnDeviceAvailability(isAvailable: true, recentFailureRate: 0)
    public static let unavailable = OnDeviceAvailability(isAvailable: false, recentFailureRate: 1)

    /// `SystemLanguageModel.default.availability == .available`.
    public let isAvailable: Bool

    /// Rolling share of on-device calls that failed, `0...1`.
    ///
    /// Guardrail false positives are a documented production reality (§2.1),
    /// not an exceptional case, so R3 asks for automatic failover once the
    /// rate crosses a threshold rather than retrying into a wall.
    public let recentFailureRate: Double

    public init(isAvailable: Bool, recentFailureRate: Double) {
        self.isAvailable = isAvailable
        self.recentFailureRate = min(max(recentFailureRate, 0), 1)
    }
}

/// Picks a route, and records why.
///
/// Routing is the main lever on unit economics: §4.3 computes that sending a
/// Sonnet-shaped task to Opus multiplies its cost by 1.65×. Hence `Decision`
/// carries a `rationale` — R5 wants per-request cost attribution, which needs
/// the reasoning stored alongside `ItineraryProposal.modelUsed`.
public struct Router: Sendable {
    /// Above this on-device failure rate, stop trying and use Haiku (R3).
    public static let failureRateFailoverThreshold = 0.5

    public struct Decision: Sendable, Hashable {
        public let route: Route
        public let rationale: String

        /// Stored in `ItineraryProposal.modelUsed` for cost attribution.
        public var modelIdentifier: String {
            switch route {
            case .onDevice, .onDeviceWithTools: "foundation-models-on-device"
            case .cloud(let model): model.rawValue
            }
        }
    }

    public init() {}

    public func route(for intent: Intent, availability: OnDeviceAvailability) -> Decision {
        switch intent {
        case .signalExtraction, .factualQuery:
            let preferred: Route = intent == .factualQuery ? .onDeviceWithTools : .onDevice
            guard availability.isAvailable else {
                // §7.1's degradation path. It raises per-user cost, which R2
                // notes has to be priced in rather than discovered later —
                // though far less than it did against Anthropic pricing.
                return Decision(
                    route: .cloud(.flash),
                    rationale: "on-device model unavailable; falling back to Flash for \(intent.rawValue)"
                )
            }
            guard availability.recentFailureRate < Self.failureRateFailoverThreshold else {
                return Decision(
                    route: .cloud(.flash),
                    rationale: """
                        on-device failure rate \
                        \(String(format: "%.0f%%", availability.recentFailureRate * 100)) \
                        exceeds threshold; failing over to Flash
                        """
                )
            }
            return Decision(route: preferred, rationale: "\(intent.rawValue) fits the on-device window")

        case .singleDayPlanning:
            // Even a single day exceeds the 4096-token on-device window once
            // the card, free slots, candidate venues, and travel times are all
            // in context (§2.1).
            return Decision(
                route: .cloud(.flash),
                rationale: "single-day planning exceeds the on-device context window"
            )

        case .complexPlanning:
            return Decision(
                route: .cloud(.v4Pro),
                rationale: "multi-day, multi-constraint planning needs the stronger model"
            )
        }
    }

    /// Recommended effort for a cloud route.
    ///
    /// Three levels, not five: DeepSeek maps `minimal`/`low` → low,
    /// `medium`/`high`/`xhigh` → high, `max`/`ultra` → max
    /// (`docs/DEEPSEEK.md`). Single-day planning used to sit at `medium`,
    /// which is now indistinguishable from `high` — so it is spelled `high`
    /// rather than pretending a middle setting exists.
    ///
    /// Both DeepSeek models accept `effort`, so this no longer returns `nil`
    /// for a model that would reject it. It stays optional because a caller
    /// may legitimately want the server default.
    public func effort(for intent: Intent, model: DeepSeekModel) -> Effort? {
        guard model.supportsEffort else { return nil }
        return switch intent {
        case .complexPlanning: .high
        case .singleDayPlanning: .high
        case .factualQuery, .signalExtraction: .low
        }
    }
}
