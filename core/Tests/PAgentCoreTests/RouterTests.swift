import Foundation
import Testing

@testable import PAgentCore

@Suite("Router")
struct RouterTests {
    private let router = Router()

    @Test("keeps tagging and fact queries on device")
    func localIntentsStayLocal() {
        // §4.3 budgets ~85% of calls to the free on-device path. These are
        // the two intents that fit a 4096-token window.
        #expect(router.route(for: .signalExtraction, availability: .available).route == .onDevice)
        #expect(
            router.route(for: .factualQuery, availability: .available).route == .onDeviceWithTools
        )
    }

    @Test("sends single-day planning to Flash")
    func singleDayGoesToSonnet() {
        let decision = router.route(for: .singleDayPlanning, availability: .available)
        #expect(decision.route == .cloud(.flash))
        #expect(decision.modelIdentifier == "deepseek-flash")
    }

    @Test("sends multi-day planning to V4-Pro")
    func complexGoesToOpus() {
        let decision = router.route(for: .complexPlanning, availability: .available)
        #expect(decision.route == .cloud(.v4Pro))
        #expect(decision.modelIdentifier == "deepseek-v4-pro")
    }

    @Test("planning goes to the cloud even when the device model is healthy")
    func planningNeverStaysLocal() {
        // §2.1's hard constraint: a day's plan needs the card, free slots,
        // candidate venues, and travel times in context at once — past 10k
        // tokens, against a 4096 window. Not a latency choice.
        for intent in [Intent.singleDayPlanning, .complexPlanning] {
            let decision = router.route(for: intent, availability: .available)
            guard case .cloud = decision.route else {
                Issue.record("\(intent) was routed locally")
                return
            }
        }
    }

    @Test("falls back to Haiku when the device has no Apple Intelligence")
    func fallsBackWhenUnavailable() {
        // R2: the iPhone 15 Pro requirement rules out most of the installed
        // base, so every local route needs a cloud twin.
        let decision = router.route(for: .signalExtraction, availability: .unavailable)
        #expect(decision.route == .cloud(.flash))
        #expect(decision.rationale.contains("unavailable"))
    }

    @Test("fails over to Haiku once the on-device failure rate is too high")
    func failsOverOnGuardrailFailures() {
        // R3: guardrail false positives are a documented production reality,
        // not an exceptional case. Retrying into a wall burns battery and
        // leaves the digest incomplete.
        let flaky = OnDeviceAvailability(isAvailable: true, recentFailureRate: 0.8)
        let decision = router.route(for: .signalExtraction, availability: flaky)

        #expect(decision.route == .cloud(.flash))
        #expect(decision.rationale.contains("failure rate"))
    }

    @Test("tolerates a failure rate below the threshold")
    func toleratesOccasionalFailures() {
        let occasional = OnDeviceAvailability(isAvailable: true, recentFailureRate: 0.2)
        #expect(router.route(for: .signalExtraction, availability: occasional).route == .onDevice)
    }

    @Test("the threshold is the boundary, not an off-by-one")
    func thresholdBoundary() {
        let atThreshold = OnDeviceAvailability(
            isAvailable: true,
            recentFailureRate: Router.failureRateFailoverThreshold
        )
        // At exactly the threshold, fail over — the rate has stopped being
        // occasional.
        #expect(router.route(for: .signalExtraction, availability: atThreshold).route == .cloud(.flash))

        let justUnder = OnDeviceAvailability(
            isAvailable: true,
            recentFailureRate: Router.failureRateFailoverThreshold - 0.01
        )
        #expect(router.route(for: .signalExtraction, availability: justUnder).route == .onDevice)
    }

    @Test("every decision records why, for cost attribution")
    func decisionsCarryRationale() {
        // R5 wants per-request cost attribution, which needs the reasoning
        // stored next to `ItineraryProposal.modelUsed` — otherwise a routing
        // regression is invisible in the bill.
        for intent in Intent.allCases {
            for availability in [OnDeviceAvailability.available, .unavailable] {
                let decision = router.route(for: intent, availability: availability)
                #expect(decision.rationale.isEmpty == false)
                #expect(decision.modelIdentifier.isEmpty == false)
            }
        }
    }

    @Test("local routes report a distinguishable model identifier")
    func localModelIdentifier() {
        let decision = router.route(for: .signalExtraction, availability: .available)
        #expect(decision.modelIdentifier == "foundation-models-on-device")
    }

    @Test("complex planning always goes to the stronger model")
    func complexPlanningGoesToV4Pro() {
        // The tiering collapsed from three Claude models to two DeepSeek ones,
        // so the old "never route planning to the cheap model" assertion is no
        // longer true — Flash *is* the single-day planner now. What still has
        // to hold is the top end: a multi-day, multi-constraint request must
        // not be quietly downgraded to save money (R5's misroute risk, now
        // pointing the other way).
        for availability in [
            OnDeviceAvailability.available,
            .unavailable,
            OnDeviceAvailability(isAvailable: true, recentFailureRate: 1.0),
        ] {
            #expect(
                router.route(for: .complexPlanning, availability: availability).route
                    == .cloud(.v4Pro)
            )
        }
    }

    @Test("on-device intents never reach the expensive model")
    func localIntentsNeverReachV4Pro() {
        // The inverse guard. Tagging and fact queries fall back to Flash when
        // the device model is unavailable (R2); falling back to V4-Pro would
        // turn a degradation path into a 30× cost multiplier.
        for availability in [
            OnDeviceAvailability.available,
            .unavailable,
            OnDeviceAvailability(isAvailable: true, recentFailureRate: 1.0),
        ] {
            for intent in [Intent.signalExtraction, .factualQuery] {
                #expect(
                    router.route(for: intent, availability: availability).route
                        != .cloud(.v4Pro)
                )
            }
        }
    }

    @Test("scales effort to the task")
    func effortRecommendations() {
        // Three levels, not five. DeepSeek maps `medium` and `xhigh` onto
        // `high`, so single-day planning — previously `medium` — is spelled
        // `high` rather than pretending a middle setting exists
        // (`docs/DEEPSEEK.md`).
        #expect(router.effort(for: .complexPlanning, model: .v4Pro) == .high)
        #expect(router.effort(for: .singleDayPlanning, model: .flash) == .high)
        #expect(router.effort(for: .factualQuery, model: .flash) == .low)
        #expect(router.effort(for: .signalExtraction, model: .flash) == .low)
    }

    @Test("every model accepts the recommended effort")
    func effortMatchesCapability() {
        // Both DeepSeek models take `output_config.effort`, so unlike the
        // Haiku case this can no longer return nil for a model that would
        // reject it. Asserted anyway: if a future model does not support it,
        // this is where the omission surfaces.
        for intent in Intent.allCases {
            for model in DeepSeekModel.allCases {
                #expect(router.effort(for: intent, model: model) != nil)
                #expect(model.supportsEffort)
            }
        }
    }
}

@Suite("OnDeviceAvailability")
struct OnDeviceAvailabilityTests {
    @Test("clamps a nonsensical failure rate")
    func clampsRate() {
        #expect(OnDeviceAvailability(isAvailable: true, recentFailureRate: 1.5).recentFailureRate == 1)
        #expect(OnDeviceAvailability(isAvailable: true, recentFailureRate: -1).recentFailureRate == 0)
    }

    @Test("the convenience values mean what they say")
    func conveniences() {
        #expect(OnDeviceAvailability.available.isAvailable)
        #expect(OnDeviceAvailability.available.recentFailureRate == 0)
        #expect(OnDeviceAvailability.unavailable.isAvailable == false)
    }
}
