import Foundation

import PAgentCore
import PAgentNet

/// Drives the conversation.
///
/// ## What changed from the Phase 0 screen
///
/// That version held one answer at a time and discarded `callingTool` /
/// `toolFinished` entirely. This holds a list of ``ConversationTurn`` and
/// records every activity, because the interesting part of a planning turn is
/// the *sequence*: think → call a tool → think about the result → answer.
///
/// What did not change is ``describe(_:)``. Those distinctions are not
/// cosmetic — "out of requests this month" and "the service is busy" need
/// different reactions from the user, and §4.2's `x-pagent-error-source`
/// header is what separates a proxy failure from an upstream one.
@Observable
@MainActor
public final class PlannerModel {
    /// How to authenticate to the proxy, given its base URL.
    ///
    /// Exists so this type does not name `AppAttestTokenProvider` directly.
    /// That type needs `DCAppAttestService`, which is iOS-only and returns
    /// `invalidKey` outside a provisioned device — so hardcoding it meant this
    /// screen could only ever render its *failure* path anywhere it could
    /// actually be run. Everything else here is `PAgentCore` and `PAgentNet`,
    /// both of which build on macOS.
    ///
    /// `nil` means App Attest, which is what the shipping app wants.
    public typealias TokenProviderFactory = @Sendable (URL) async -> any DeviceTokenProviding

    private let makeTokenProvider: TokenProviderFactory?
    private let store: any ConversationStoring
    private var task: Task<Void, Never>?

    public private(set) var turns: [ConversationTurn] = []
    public private(set) var conversations: [ConversationSummary] = []
    /// `nil` until the first turn — a conversation row is only created once
    /// there is something in it, so opening the app does not litter the list
    /// with empties.
    public private(set) var conversationID: UUID?

    /// Set when a save fails. Surfaced as a banner rather than thrown: losing
    /// the transcript is bad, losing the answer on screen because the disk is
    /// full would be worse.
    public private(set) var storeWarning: String?

    public init(
        tokenProvider: TokenProviderFactory? = nil,
        store: any ConversationStoring = NullConversationStore()
    ) {
        self.makeTokenProvider = tokenProvider
        self.store = store
    }

    // MARK: - Conversations

    public func loadConversations() {
        do {
            conversations = try store.recentConversations(limit: 50)
        } catch {
            storeWarning = "无法读取历史对话：\(error.localizedDescription)"
        }
    }

    public func open(_ id: UUID) {
        task?.cancel()
        do {
            turns = try store.turns(in: id)
            conversationID = id
            storeWarning = nil
        } catch {
            storeWarning = "无法打开这段对话：\(error.localizedDescription)"
        }
    }

    public func startNewConversation() {
        task?.cancel()
        turns.removeAll()
        conversationID = nil
        storeWarning = nil
    }

    public func delete(_ id: UUID) {
        do {
            try store.deleteConversation(id)
            if conversationID == id { startNewConversation() }
            loadConversations()
        } catch {
            storeWarning = "删除失败：\(error.localizedDescription)"
        }
    }

    private func persist(_ turn: ConversationTurn) {
        do {
            let id: UUID
            if let existing = conversationID {
                id = existing
            } else {
                id = try store.createConversation(titledFrom: turn.prompt)
                conversationID = id
            }
            try store.append(turn, to: id)
            loadConversations()
        } catch {
            // Deliberately not rethrown. The turn is on screen and correct;
            // only its persistence failed, and the user can still read it.
            storeWarning = "这次对话没能保存：\(error.localizedDescription)"
        }
    }

    public var isRunning: Bool { turns.last?.status.isStreaming ?? false }

    /// The most recent request body, for the §9.3 disclosure screen.
    public var lastRequestBody: String? {
        turns.reversed().compactMap(\.requestBody).first
    }

    // MARK: - Running

    public func send(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        task?.cancel()
        let turn = ConversationTurn(prompt: trimmed)
        turns.append(turn)
        task = Task { [weak self] in await self?.perform(turn) }
    }

    /// Re-runs a turn's prompt as a new turn.
    ///
    /// A new turn rather than mutating the old one: the failed attempt is part
    /// of what happened, and quietly rewriting history would hide that a retry
    /// was needed.
    public func retry(_ turn: ConversationTurn) {
        send(turn.prompt)
    }

    public func cancel() {
        task?.cancel()
        if let turn = turns.last, turn.status.isStreaming {
            turn.status = .failed(
                .init(title: "已取消", detail: "这次请求被你取消了。", isRetryable: true)
            )
        }
    }

    public func clear() { startNewConversation() }

    private func perform(_ turn: ConversationTurn) async {
        guard let baseURL = ProxyConfiguration.baseURL else {
            turn.status = .failed(
                .init(
                    title: "尚未配置代理地址",
                    detail: "请在 Info.plist 中设置 PAgentProxyBaseURL。",
                    isRetryable: false
                )
            )
            return
        }

        let request: MessagesRequest
        do {
            request = try MessagesRequest(
                model: .flash,
                maxTokens: 8_000,
                stream: true,
                thinking: .enabled(display: .summarized),
                outputConfig: OutputConfig(effort: .low),
                prefix: PAgentPrompt.prefix(card: Self.placeholderCard),
                messages: [
                    .user([
                        // Time goes in the user turn, never the system prompt
                        // (R8). `currentTimeBlock` is the sanctioned route.
                        currentTimeBlock(at: .now, timeZone: .current),
                        .text(turn.prompt),
                    ])
                ]
            )
            turn.requestBody = String(decoding: try request.encoded(), as: UTF8.self)
        } catch {
            turn.status = .failed(
                .init(title: "请求构造失败", detail: String(describing: error), isRetryable: false)
            )
            return
        }

        let tokenProvider: any DeviceTokenProviding
        if let makeTokenProvider {
            tokenProvider = await makeTokenProvider(baseURL)
        } else {
            // `canImport(DeviceCheck)` is true on macOS — the framework exists,
            // `DCAppAttestService` just is not usable there. The platform is
            // what actually differs, so test for that.
            #if os(iOS)
                tokenProvider = await AppAttestTokenProvider(baseURL: baseURL).tokenProvider()
            #else
                // The macOS harness always injects a provider, so reaching here
                // means a caller forgot to. Failing loudly beats falling back
                // to something unauthenticated and surfacing it as a 401.
                turn.status = .failed(
                    .init(
                        title: "未注入设备认证",
                        detail: "此平台没有 App Attest，调用方必须传入 tokenProvider。",
                        isRetryable: false
                    )
                )
                return
            #endif
        }

        let loop = AgentLoop(
            transport: ProxyTransport(baseURL: baseURL, tokenProvider: tokenProvider),
            executor: UnavailableToolExecutor()
        )

        do {
            _ = try await loop.run(request) { [weak turn] activity in
                Task { @MainActor [weak turn] in
                    guard let turn else { return }
                    Self.apply(activity, to: turn)
                }
            }
            if !Task.isCancelled { turn.status = .finished }
        } catch is CancellationError {
            // `cancel()` already set the status; nothing to add.
        } catch {
            turn.status = .failed(Self.describe(error))
        }

        // Saved whatever the outcome. A failed turn is part of the history —
        // storing only successes would make the transcript a record of a
        // conversation that did not happen.
        if !Task.isCancelled { persist(turn) }
    }

    private static func apply(_ activity: AgentActivity, to turn: ConversationTurn) {
        switch activity {
        case .thinking(let delta):
            turn.appendThinking(delta)
        case .text(let delta):
            turn.appendText(delta)
        case .callingTool(let name):
            turn.startTool(named: name)
        case .toolFinished(let name, let failed):
            turn.finishTool(named: name, failed: failed)
        case .roundCompleted(_, let usage):
            // Accumulated across rounds: a tool-using turn is several API
            // calls, and showing only the last would under-report the cost.
            var total = turn.usage ?? Usage()
            total.inputTokens += usage.inputTokens
            total.outputTokens += usage.outputTokens
            total.cacheCreationInputTokens += usage.cacheCreationInputTokens
            total.cacheReadInputTokens += usage.cacheReadInputTokens
            turn.usage = total
        }
    }

    // MARK: - Placeholder card

    /// §10 Phase 0's acceptance explicitly excludes personal data, so this is
    /// a literal rather than a generated card. DeepSeek publishes no minimum
    /// cacheable length, so even this short prefix can cache — but the first
    /// request still misses, because caching takes seconds to build.
    private static let placeholderCard = ProfileCard(
        markdown: "## 画像\n（Phase 0 占位，不含个人数据。）",
        tokenCount: 20,
        includedSlugs: [],
        omittedSlugs: []
    )

    // MARK: - Errors

    /// Turns a typed error into something worth reading.
    ///
    /// The distinctions matter to the user: "out of requests this month" and
    /// "the service is busy" need different reactions, and the proxy's
    /// `x-pagent-error-source` header is what separates them (§4.2).
    static func describe(_ error: any Error) -> ConversationTurn.Failure {
        if let transport = error as? ProxyTransportError {
            switch transport {
            case .unauthenticated(let message):
                return .init(
                    title: "设备认证失败",
                    detail: "\(message)\n需要重新注册设备。",
                    isRetryable: false
                )
            case .quotaExhausted(let message, _):
                return .init(title: "本月额度已用完", detail: message, isRetryable: false)
            case .rateLimited(let message, let retryAfter):
                let wait = retryAfter.map { " 约 \(Int($0)) 秒后可重试。" } ?? ""
                return .init(title: "服务繁忙", detail: message + wait, isRetryable: true)
            case .invalidRequest(let message):
                return .init(title: "请求被拒绝", detail: message, isRetryable: false)
            case .http(let status, _, let message, let source):
                return .init(
                    title: "HTTP \(status)（\(source.rawValue)）",
                    detail: message,
                    isRetryable: transport.isTransient
                )
            case .transport(let message):
                return .init(title: "网络不可用", detail: message, isRetryable: true)
            case .malformedResponse(let message):
                return .init(title: "响应无法解析", detail: message, isRetryable: false)
            }
        }

        if let loop = error as? AgentLoopError {
            switch loop {
            case .refused:
                // HTTP 200 with an empty content array (§7.3). Not a bug.
                return .init(
                    title: "模型拒绝了这次请求",
                    detail: "换一种问法试试。",
                    isRetryable: false
                )
            case .outputTruncated:
                return .init(title: "回答被截断", detail: "输出超出了 max_tokens。", isRetryable: true)
            case .contextWindowExceeded:
                return .init(title: "上下文超出窗口", detail: "对话过长，需要重新开始。", isRetryable: false)
            case .roundLimitReached(let limit):
                return .init(title: "工具调用轮次过多", detail: "已达到 \(limit) 轮上限。", isRetryable: false)
            case .unknownTool(let name):
                return .init(title: "未知工具", detail: name, isRetryable: false)
            }
        }

        return .init(title: "出错了", detail: error.localizedDescription, isRetryable: false)
    }
}

/// Reports every tool as unavailable.
///
/// Phase 0 has no EventKit or MapKit integration — that is Phase 1 (§10). The
/// honest behaviour is to tell the model so, rather than to return invented
/// data: a fabricated free slot would produce a plausible-looking plan built
/// on nothing, which is worse than a model that says it cannot check the
/// calendar yet.
///
/// Throwing (rather than returning text) is what routes this through
/// ``PAgentCore/AgentLoop``'s failed-tool path, which returns a `tool_result`
/// with `is_error: true`. Dropping the result instead would leave a `tool_use`
/// unanswered and the API would reject the next request (§7.3).
public struct UnavailableToolExecutor: ToolExecuting {
    struct NotImplemented: LocalizedError {
        let tool: String
        var errorDescription: String? {
            "`\(tool)` is not available in this build: the device-side "
                + "integration lands in Phase 1. Answer without it, and say so."
        }
    }

    public init() {}

    public func execute(name: String, input: JSONValue) async throws -> String {
        throw NotImplemented(tool: name)
    }
}
