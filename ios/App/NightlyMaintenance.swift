import BackgroundTasks
import Foundation
import SwiftData

import PAgentCore
import PAgentData

/// The nightly background pass (§6.1).
///
/// ## What runs today, and what is still Phase 2
///
/// Two independent jobs share this task. Only one of them exists yet:
///
/// - **Retention sweep** — implemented and tested
///   (``PAgentData/RetentionSweeper``). Deletes signals past their §5.1
///   horizon.
/// - **Digest** — Phase 2 (§10). Batches undigested signals through the
///   on-device model, updates the interest graph, and regenerates the profile
///   card. The token budgeting (``PAgentCore/DigestBatcher``), decay
///   (``PAgentCore/InterestGraphUpdater``), and card rendering
///   (``PAgentCore/ProfileCardBuilder``) are all built and tested; what is
///   missing is the `FoundationModels` call between them, which needs a
///   device with Apple Intelligence to develop against.
///
/// They are deliberately **separate passes**, in that order. §9.3 undertakes
/// to App Review that retention is enforced automatically, and the digest is
/// the part most likely to fail — a guardrail false-positive storm is a
/// documented production reality (§2.1, R3). Running retention first means a
/// broken digest cannot quietly extend the 180-day promise indefinitely.
enum NightlyMaintenance {
    static let taskIdentifier = "com.example.PAgent.nightly-digest"

    /// Registers the handler. Must be called before launch completes.
    static func register(container: ModelContainer) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(TaskHandle(task: processing), container: container)
        }
    }

    /// Carries the system's task object into the async sweep.
    ///
    /// `BGTask` is not `Sendable` and the SDK offers no async registration
    /// API, so some unchecked step is unavoidable here. This is the narrowest
    /// one available, and the conformance is describing a guarantee the
    /// scheduler already makes rather than asserting one we hope holds: the
    /// system hands the launch handler sole ownership of the task object, and
    /// everything below funnels every access to it through a single `Task`.
    ///
    /// The one access from elsewhere is `expirationHandler`, which the system
    /// invokes on its own thread — and that closure only calls
    /// `Task.cancel()`, which is safe from anywhere.
    private struct TaskHandle: @unchecked Sendable {
        let task: BGProcessingTask
    }

    /// Asks the system to run the task tonight.
    ///
    /// `requiresExternalPower` is the §6.1 requirement rather than a
    /// preference: on-device inference over a day of signals is expensive
    /// enough that running it on battery would show up as drain, and Phase 2's
    /// acceptance bar is <2%.
    static func schedule(earliestAfter interval: TimeInterval = 4 * 60 * 60) {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Submission fails in the simulator and when a request is already
            // queued. Neither is actionable, and neither should be fatal.
            print("[PAgent] could not schedule nightly maintenance: \(error)")
        }
    }

    private static func handle(_ handle: TaskHandle, container: ModelContainer) {
        // Re-schedule first. If the work below runs long and the system
        // terminates us, a request already in the queue means tonight's
        // failure does not become a permanent stop.
        schedule(earliestAfter: 20 * 60 * 60)

        let work = Task {
            let sweeper = RetentionSweeper(modelContainer: container)
            do {
                let deleted = try await sweeper.sweep()
                // Metadata only, consistent with the proxy's logging rule
                // (§4.2) — a count, never a payload.
                print("[PAgent] retention sweep removed \(deleted) signal(s)")
                handle.task.setTaskCompleted(success: true)
            } catch {
                print("[PAgent] retention sweep failed: \(error)")
                handle.task.setTaskCompleted(success: false)
            }
        }

        // Cancellation is the only thing the system's thread touches, and
        // `Task.cancel()` is safe from anywhere.
        handle.task.expirationHandler = { work.cancel() }
    }
}
