import SwiftData
import SwiftUI

import PAgentCore
import PAgentNet

/// The Phase 0 acceptance screen.
///
/// §10 Phase 0 asks for one thing to work end to end on a real device:
/// *locally construct `messages` → through the proxy → Claude streams text →
/// the UI renders it*, **with no personal data involved**. This view is that
/// path, and nothing more.
///
/// Two deliberate omissions, both of which are later phases:
///
/// - **No profile card.** The card is sent as a literal placeholder here, so
///   the acceptance run carries no personal data at all. Generating a real one
///   needs the §6.1 digest, which is Phase 2.
/// - **No tool execution.** `search_calendar` and friends need EventKit and
///   MapKit, which is Phase 1. ``UnavailableToolExecutor`` returns a described
///   failure instead, which the model can route around — see the note there.
///
/// What it *does* surface, prominently, is `cache_read_input_tokens`. That is
/// the only observable signal for R8 (§7.3: under-length or byte-unstable
/// prefixes fail silently), and Phase 1's acceptance bar is a >80% hit rate.
/// Putting it on screen means a broken cache is noticed during development
/// rather than in a bill.
struct PlannerView: View {
    @State private var model = PlannerModel()
    @State private var prompt = "用三句话介绍你能帮我做什么。"

    var body: some View {
        Form {
            Section("请求") {
                TextField("想让 PAgent 做什么", text: $prompt, axis: .vertical)
                    .lineLimit(2...5)
                    .disabled(model.isRunning)

                Button(model.isRunning ? "正在生成…" : "发送") {
                    model.run(prompt: prompt)
                }
                .disabled(model.isRunning || prompt.isEmpty)
            }

            if let failure = model.failure {
                Section("失败") {
                    Text(failure.title).font(.subheadline.weight(.semibold))
                    Text(failure.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if failure.isRetryable {
                        // Only offered when retrying could actually work. A
                        // planning request costs real money (§4.3), so the
                        // transport never retries on its own — see
                        // `ProxyTransportError.isTransient`.
                        Button("重试") { model.run(prompt: prompt) }
                    }
                }
            }

            if !model.thinking.isEmpty {
                Section("思考过程") {
                    // Arrives only because the request sets
                    // `display: "summarized"`. The API default is `omitted`,
                    // which renders as a long blank pause (§7.3).
                    Text(model.thinking)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !model.answer.isEmpty {
                Section("回答") {
                    Text(model.answer)
                }
            }

            if let usage = model.usage {
                Section("用量") {
                    LabeledContent("输入", value: "\(usage.inputTokens)")
                    LabeledContent("输出", value: "\(usage.outputTokens)")
                    // Always 0 on DeepSeek's compat endpoint — there is no
                    // explicit write step to report (docs/DEEPSEEK.md).
                    LabeledContent("缓存写入", value: "\(usage.cacheCreationInputTokens)")
                    LabeledContent("缓存读取") {
                        // The R8 signal. Zero across repeated identical
                        // requests means the cache is silently broken.
                        Text("\(usage.cacheReadInputTokens)")
                            .foregroundStyle(usage.cacheHit ? .green : .secondary)
                    }
                    if !usage.cacheHit {
                        Text("本次未命中缓存。缓存构建需要几秒，第二次相同请求应当命中；若始终为 0，说明稳定前缀的字节在两次请求之间变了（R8）。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                NavigationLink("我发出去了什么") {
                    OutboundDisclosureView(lastRequestBody: model.lastRequestBody)
                }
            }
        }
        .navigationTitle("PAgent")
    }
}

// MARK: - Model

@Observable
@MainActor
final class PlannerModel {
    struct Failure {
        let title: String
        let detail: String
        let isRetryable: Bool
    }

    private(set) var isRunning = false
    private(set) var thinking = ""
    private(set) var answer = ""
    private(set) var usage: Usage?
    private(set) var failure: Failure?
    /// Kept so the disclosure screen can show the exact bytes that were sent.
    private(set) var lastRequestBody: String?

    private var task: Task<Void, Never>?

    /// A placeholder card.
    ///
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

    func run(prompt: String) {
        task?.cancel()
        thinking = ""
        answer = ""
        usage = nil
        failure = nil
        isRunning = true

        task = Task { [weak self] in
            await self?.perform(prompt: prompt)
        }
    }

    private func perform(prompt: String) async {
        defer { isRunning = false }

        guard let baseURL = ProxyConfiguration.baseURL else {
            failure = Failure(
                title: "尚未配置代理地址",
                detail: "请在 Info.plist 中设置 PAgentProxyBaseURL。",
                isRetryable: false
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
                        .text(prompt),
                    ])
                ]
            )
            lastRequestBody = String(decoding: try request.encoded(), as: UTF8.self)
        } catch {
            failure = Failure(
                title: "请求构造失败",
                detail: String(describing: error),
                isRetryable: false
            )
            return
        }

        let provider = AppAttestTokenProvider(baseURL: baseURL)
        let loop = AgentLoop(
            transport: ProxyTransport(
                baseURL: baseURL,
                tokenProvider: await provider.tokenProvider()
            ),
            executor: UnavailableToolExecutor()
        )

        do {
            _ = try await loop.run(request) { [weak self] activity in
                Task { @MainActor [weak self] in
                    self?.apply(activity)
                }
            }
        } catch {
            failure = Self.describe(error)
        }
    }

    private func apply(_ activity: AgentActivity) {
        switch activity {
        case .thinking(let delta):
            thinking += delta
        case .text(let delta):
            answer += delta
        case .roundCompleted(_, let roundUsage):
            usage = roundUsage
        case .callingTool, .toolFinished:
            break
        }
    }

    /// Turns a typed error into something worth reading.
    ///
    /// The distinctions matter to the user: "out of requests this month" and
    /// "the service is busy" need different reactions, and the proxy's
    /// `x-pagent-error-source` header is what separates them (§4.2).
    private static func describe(_ error: any Error) -> Failure {
        if let transport = error as? ProxyTransportError {
            switch transport {
            case .unauthenticated(let message):
                return Failure(
                    title: "设备认证失败",
                    detail: "\(message)\n需要重新注册设备。",
                    isRetryable: false
                )
            case .quotaExhausted(let message, _):
                return Failure(
                    title: "本月额度已用完",
                    detail: message,
                    isRetryable: false
                )
            case .rateLimited(let message, let retryAfter):
                let wait = retryAfter.map { " 约 \(Int($0)) 秒后可重试。" } ?? ""
                return Failure(title: "服务繁忙", detail: message + wait, isRetryable: true)
            case .invalidRequest(let message):
                return Failure(title: "请求被拒绝", detail: message, isRetryable: false)
            case .http(let status, _, let message, let source):
                return Failure(
                    title: "HTTP \(status)（\(source.rawValue)）",
                    detail: message,
                    isRetryable: transport.isTransient
                )
            case .transport(let message):
                return Failure(title: "网络不可用", detail: message, isRetryable: true)
            case .malformedResponse(let message):
                return Failure(title: "响应无法解析", detail: message, isRetryable: false)
            }
        }

        if let loop = error as? AgentLoopError {
            switch loop {
            case .refused:
                // HTTP 200 with an empty content array (§7.3). Not a bug.
                return Failure(
                    title: "模型拒绝了这次请求",
                    detail: "换一种问法试试。",
                    isRetryable: false
                )
            case .outputTruncated:
                return Failure(
                    title: "回答被截断",
                    detail: "输出超出了 max_tokens。",
                    isRetryable: true
                )
            case .contextWindowExceeded:
                return Failure(
                    title: "上下文超出窗口",
                    detail: "对话过长，需要重新开始。",
                    isRetryable: false
                )
            case .roundLimitReached(let limit):
                return Failure(
                    title: "工具调用轮次过多",
                    detail: "已达到 \(limit) 轮上限。",
                    isRetryable: false
                )
            case .unknownTool(let name):
                return Failure(title: "未知工具", detail: name, isRetryable: false)
            }
        }

        return Failure(
            title: "出错了",
            detail: error.localizedDescription,
            isRetryable: false
        )
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
struct UnavailableToolExecutor: ToolExecuting {
    struct NotImplemented: LocalizedError {
        let tool: String
        var errorDescription: String? {
            "`\(tool)` is not available in this build: the device-side "
                + "integration lands in Phase 1. Answer without it, and say so."
        }
    }

    func execute(name: String, input: JSONValue) async throws -> String {
        throw NotImplemented(tool: name)
    }
}

// MARK: - Disclosure

/// §9.3 clause 5.1.2 — the user can see exactly what left the device.
///
/// Shows the real request body, not a summary of it. The claim in §1 is that
/// only a ≤500-token card leaves the device; a screen that paraphrased the
/// payload would be asking the user to take that on trust.
private struct OutboundDisclosureView: View {
    let lastRequestBody: String?

    var body: some View {
        Form {
            Section("说明") {
                Text(
                    """
                    复杂规划会把一张不超过 500 token 的画像卡发送至 Anthropic 处理。\
                    你的日历、位置、照片等原始数据不会离开这台设备。

                    下面是上一次请求的完整内容——不是摘要，而是实际发出的字节。
                    """
                )
                .font(.footnote)
            }

            Section("上一次请求") {
                if let lastRequestBody {
                    Text(lastRequestBody)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    Text("还没有发出过任何请求。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("我发出去了什么")
    }
}
