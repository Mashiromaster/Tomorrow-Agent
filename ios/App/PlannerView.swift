import SwiftUI

import PAgentCore

/// The conversation screen.
///
/// ## Why a transcript rather than a form
///
/// The Phase 0 version was a `Form` with one request and one answer, built to
/// prove the chain worked rather than to be used. A resident agent is a
/// conversation: what the model did — thought, called a tool, thought again —
/// is as much the content as the final prose, and a form has nowhere to put
/// that sequence.
///
/// ## What survives from the acceptance screen
///
/// Two things, because both are load-bearing rather than decorative:
///
/// - **`cache_read_input_tokens`**, in the per-turn footer. It is the only
///   observable signal for R8 (§7.3: byte-unstable prefixes fail silently),
///   and Phase 1's bar is a >80% hit rate. On screen means a broken cache is
///   noticed during development rather than in a bill.
/// - **"我发出去了什么"** (§9.3 clause 5.1.2) — the real request bytes, not a
///   summary. §1 claims only a ≤500-token card leaves the device; a screen
///   that paraphrased would be asking the user to take that on trust.
public struct PlannerView: View {
    @State private var model: PlannerModel
    @State private var draft = ""
    @State private var showingDisclosure = false
    @FocusState private var composerFocused: Bool

    /// - Parameter tokenProvider: how to authenticate to the proxy. Defaults
    ///   to App Attest; the macOS harness in `tools/` passes a signed-token
    ///   stand-in so this can run where `DCAppAttestService` does not exist.
    private let initialPrompt: String?

    /// - Parameter initialPrompt: sent once on appear. Used by the macOS
    ///   harness to reach a mid-conversation state without driving the
    ///   keyboard; `nil` in the shipping app.
    public init(
        tokenProvider: PlannerModel.TokenProviderFactory? = nil,
        initialPrompt: String? = nil
    ) {
        _model = State(initialValue: PlannerModel(tokenProvider: tokenProvider))
        self.initialPrompt = initialPrompt
    }

    public var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
        // `Color(.windowBackground)` / `.systemBackground` rather than the
        // semantic `.background` style: that one resolves to a material, which
        // on macOS renders translucent and shows whatever is behind the
        // window. A transcript has to be readable over anything.
        #if os(macOS)
            .background(Color(nsColor: .windowBackgroundColor))
        #else
            .background(Color(uiColor: .systemBackground))
        #endif
        .navigationTitle("PAgent")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("我发出去了什么", systemImage: "doc.text.magnifyingglass") {
                        showingDisclosure = true
                    }
                    .disabled(model.lastRequestBody == nil)

                    Button("清空对话", systemImage: "trash", role: .destructive) {
                        model.clear()
                    }
                    .disabled(model.turns.isEmpty)
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingDisclosure) {
            OutboundDisclosureView(requestBody: model.lastRequestBody)
        }
        .task {
            if let initialPrompt, model.turns.isEmpty { model.send(initialPrompt) }
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if model.turns.isEmpty {
                        EmptyStateView { draft = $0 }
                            .padding(.top, 48)
                    }
                    ForEach(model.turns) { turn in
                        TurnView(turn: turn) { model.retry(turn) }
                            .id(turn.id)
                    }
                    // Scroll anchor. Scrolling to the last *turn* would put its
                    // top at the top of the viewport, hiding the streaming text
                    // below the fold — which is the part worth watching.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.turns.count) { scrollToBottom(proxy) }
            .onChange(of: model.turns.last?.segments.count) { scrollToBottom(proxy) }
        }
    }

    private static let bottomAnchor = "bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            inputField
            sendButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    // Split out of `composer` rather than written as one chain: a long
    // modifier chain with a `#if` in the middle made the type-checker give up
    // entirely ("failed to produce diagnostic for expression"), pointing at a
    // line several statements away.
    private var inputField: some View {
        TextField("想让 PAgent 做什么…", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...6)
            .focused($composerFocused)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(fieldBackground)
            .onSubmit(submit)
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.quaternary.opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.separator, lineWidth: 0.5)
            )
    }

    private var sendButton: some View {
        // An explicit closure rather than `action: isRunning ? model.cancel
        // : submit` — a ternary over a method reference and a local function
        // is what actually broke inference, and the compiler blamed `.help`
        // two lines down.
        Button {
            if model.isRunning { model.cancel() } else { submit() }
        } label: {
            Image(systemName: model.isRunning ? "stop.fill" : "arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(sendTint))
        }
        .buttonStyle(.plain)
        .disabled(!model.isRunning && draft.trimmed.isEmpty)
        .help(model.isRunning ? "停止" : "发送")
    }

    /// Concrete `Color` rather than an opaque `ShapeStyle`: mixing
    /// `AnyShapeStyle` branches here defeated the type-checker outright
    /// ("failed to produce diagnostic"), and the button only ever needs three
    /// flat fills.
    private var sendTint: Color {
        if model.isRunning { return .secondary }
        return draft.trimmed.isEmpty ? Color.secondary.opacity(0.4) : .accentColor
    }

    private func submit() {
        let prompt = draft.trimmed
        guard !prompt.isEmpty, !model.isRunning else { return }
        model.send(prompt)
        draft = ""
        composerFocused = true
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Empty state

/// Shown before the first turn.
///
/// The suggestions are not decoration: two of the three need tools that do not
/// exist until Phase 1, so tapping one shows what the agent does when it
/// cannot check — which is the honest behaviour worth seeing early.
private struct EmptyStateView: View {
    let onPick: (String) -> Void

    private static let suggestions = [
        "用三句话介绍你能帮我做什么。",
        "我这周六上午有空吗？",
        "帮我在城西找个独立书店，算一下过去要多久。",
    ]

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: 34))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("今天想安排点什么？")
                    .font(.title3.weight(.semibold))
                Text("PAgent 只会给出提案，写入日历需要你逐项确认。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 8) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button { onPick(suggestion) } label: {
                        Text(suggestion)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(.quaternary.opacity(0.4))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - One turn

private struct TurnView: View {
    let turn: ConversationTurn
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PromptBubble(text: turn.prompt)

            if turn.isEmpty && turn.status.isStreaming {
                WorkingIndicator()
            }

            ForEach(turn.segments) { segment in
                switch segment {
                case .thinking(let block): ThinkingView(block: block)
                case .text(let block): AnswerView(block: block)
                case .tool(let call): ToolCallView(call: call)
                }
            }

            if let failure = turn.failure {
                FailureView(failure: failure, onRetry: onRetry)
            }

            if let usage = turn.usage {
                UsageFooter(usage: usage)
            }
        }
    }
}

private struct PromptBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )
        }
    }
}

/// The gap between sending and the first delta.
///
/// §7.4 is explicit that perceived latency is what matters: a multi-round turn
/// takes real seconds, and an unmarked blank space reads as a hang.
private struct WorkingIndicator: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.tint)
                .frame(width: 7, height: 7)
                .opacity(pulse ? 0.25 : 1)
                .animation(.easeInOut(duration: 0.65).repeatForever(), value: pulse)
            Text("思考中…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .onAppear { pulse = true }
    }
}

/// Summarised reasoning, collapsible.
///
/// Arrives only because the request sets `display: "summarized"` — the API
/// default is `omitted`, which renders as a long blank pause (§7.3).
private struct ThinkingView: View {
    @Bindable var block: ConversationTurn.ThinkingBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { block.isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(block.isExpanded ? 90 : 0))
                    Text("思考过程")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if block.isExpanded {
                Text(block.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.quaternary).frame(width: 2)
                    }
            } else if let summary = block.summary {
                // A collapsed block still says something. A bare "思考过程"
                // row carries no information at all, and a turn can hold
                // several of them — one before each tool call.
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.leading, 14)
            }
        }
    }
}

private struct AnswerView: View {
    @Bindable var block: ConversationTurn.TextBlock

    var body: some View {
        Text(block.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One tool invocation.
///
/// Shown even when it fails — especially when it fails. In Phase 0 every tool
/// is unavailable, and seeing the model route around that is the point.
private struct ToolCallView: View {
    @Bindable var call: ConversationTurn.ToolCall

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(call.name)
                .font(.system(.caption, design: .monospaced))
            if call.failed {
                // In Phase 0 every tool is unavailable by design, so a bare
                // orange icon would read as a bug. Say which it is.
                Text("本阶段不可用")
                    .font(.caption2)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(call.failed ? .orange : .secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.3))
        )
    }

    @ViewBuilder private var icon: some View {
        if !call.finished {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: call.failed ? "exclamationmark.triangle.fill" : "checkmark")
                .font(.caption2.weight(.bold))
        }
    }
}

private struct FailureView: View {
    let failure: ConversationTurn.Failure
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(failure.title, systemImage: "exclamationmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(failure.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if failure.isRetryable {
                // Only offered when retrying could actually work. A planning
                // request costs real money (§4.3), so the transport never
                // retries on its own — see `ProxyTransportError.isTransient`.
                Button("重试", action: onRetry)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.orange.opacity(0.08))
        )
    }
}

/// Token counts for one turn.
///
/// `cache_read` is the reason this is on screen at all: it is the only
/// observable R8 signal, and a silent cache failure costs 30× on input
/// without producing a single error.
private struct UsageFooter: View {
    let usage: Usage

    var body: some View {
        HStack(spacing: 14) {
            metric("arrow.up", "\(usage.inputTokens)", .secondary)
            metric("arrow.down", "\(usage.outputTokens)", .secondary)
            metric(
                "bolt.fill",
                "\(usage.cacheReadInputTokens)",
                usage.cacheHit ? .green : .secondary
            )
            if !usage.cacheHit {
                Text("未命中缓存")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("缓存构建需要几秒，第二次相同请求应当命中；若始终为 0，说明稳定前缀的字节在两次请求之间变了（R8）。")
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
    }

    private func metric(
        _ symbol: String, _ value: String, _ tint: some ShapeStyle
    ) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text(value).monospacedDigit()
        }
        .foregroundStyle(tint)
    }
}

// MARK: - Disclosure

/// §9.3 clause 5.1.2 — the user can see exactly what left the device.
///
/// Shows the real request body, not a summary of it. The claim in §1 is that
/// only a ≤500-token card leaves the device; a screen that paraphrased the
/// payload would be asking the user to take that on trust.
struct OutboundDisclosureView: View {
    let requestBody: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(
                        """
                        复杂规划会把一张不超过 500 token 的画像卡发送至模型处理。\
                        你的日历、位置、照片等原始数据不会离开这台设备。

                        下面是上一次请求的完整内容——不是摘要，而是实际发出的字节。
                        """
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    if let requestBody {
                        Text(requestBody)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(.quaternary.opacity(0.3))
                            )
                    } else {
                        Text("还没有发出过任何请求。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .navigationTitle("我发出去了什么")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}
