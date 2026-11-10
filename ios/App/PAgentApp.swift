import SwiftData
import SwiftUI

import PAgentCore
import PAgentData
import PAgentNet

/// Where the proxy lives, and the one thing that must be set before anything
/// works.
///
/// Read from the bundle rather than hardcoded so a TestFlight build can point
/// at a staging proxy without a code change. There is deliberately no default:
/// a fallback URL would turn "forgot to configure the proxy" into a confusing
/// network error at the first planning request instead of a clear failure at
/// launch.
enum ProxyConfiguration {
    static var baseURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "PAgentProxyBaseURL") as? String,
            !raw.isEmpty,
            let url = URL(string: raw)
        else { return nil }
        return url
    }
}

@main
struct PAgentApp: App {
    /// Built once at launch and shared by every view.
    ///
    /// `container` rather than `.modelContainer(for:)` because the store lives
    /// in the App Group (the Share Extension writes to it too), and because a
    /// failure here needs to be *visible* — see ``StartupFailureView``. A
    /// `try!` would crash on a migration problem with no explanation, which is
    /// the worst possible first-launch experience.
    private let startup: Result<ModelContainer, any Error>

    init() {
        startup = Self.makeContainer()
        if case .success(let container) = startup {
            NightlyMaintenance.register(container: container)
        }
    }

    private static func makeContainer() -> Result<ModelContainer, any Error> {
        guard let storeURL = PAgentSchema.sharedStoreURL() else {
            // Falling back to a private-container store would split the log in
            // two: the extension would write signals the app could never read.
            // That presents as "shared items sometimes vanish", which is far
            // harder to diagnose than refusing to start.
            return .failure(StartupError.appGroupUnavailable)
        }
        do {
            return .success(try PAgentSchema.container(url: storeURL))
        } catch {
            return .failure(error)
        }
    }

    var body: some Scene {
        WindowGroup {
            switch startup {
            case .success(let container):
                RootView()
                    .modelContainer(container)
                    .task { NightlyMaintenance.schedule() }
            case .failure(let error):
                StartupFailureView(error: error)
            }
        }
    }

    enum StartupError: Error, LocalizedError {
        case appGroupUnavailable

        var errorDescription: String? {
            switch self {
            case .appGroupUnavailable:
                """
                无法访问共享数据容器。请确认 App 与 Share Extension 都配置了 \
                App Group「\(PAgentSchema.appGroupIdentifier)」。
                """
            }
        }
    }
}

/// Shown when the store could not be opened.
///
/// Worth a real screen rather than a crash: the two causes — a missing App
/// Group entitlement and a failed migration — are both configuration problems
/// whose fix depends on knowing which one happened.
private struct StartupFailureView: View {
    let error: any Error

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("PAgent 无法启动")
                .font(.headline)
            Text(error.localizedDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

private struct RootView: View {
    var body: some View {
        NavigationStack {
            PlannerView()
        }
    }
}
