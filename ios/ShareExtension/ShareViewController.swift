import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

import PAgentCore
import PAgentData

/// Captures a shared link or snippet into the signal log.
///
/// ## What this does, and what it deliberately does not
///
/// It writes one ``SignalEvent`` and exits. It does not summarise, classify,
/// fetch the URL, or call a model — all of which happen later, in the nightly
/// digest (§6.1), in the app's process.
///
/// That split is a §9.4 decision rather than a convenience. Shared content is
/// untrusted input, and the narrower the code that touches it before it is
/// safely at rest, the smaller the surface. The extension has no App Attest
/// entitlement and makes no network calls, so there is no path from a hostile
/// shared page to the proxy through this process at all.
///
/// It also stores the content **verbatim**. §5.1 keeps raw signals replayable
/// because normalisation rules change and replay is the only correction
/// mechanism; §9.4 adds that pre-processing untrusted text is itself a risk.
/// Sanitisation happens at render time, in ``PAgentCore/UntrustedContent``,
/// on a copy.
final class ShareViewController: UIViewController {
    private enum Outcome {
        case saved
        case nothingUsable
        case storeUnavailable(String)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await handleRequest() }
    }

    private func handleRequest() async {
        let outcome = await capture()
        await MainActor.run { present(outcome) }
    }

    // MARK: - Capture

    private func capture() async -> Outcome {
        guard let captured = await extractSharedContent() else {
            return .nothingUsable
        }

        do {
            // A fresh container per invocation. The extension is short-lived
            // and may be launched while the app is also running, so there is
            // nothing to reuse and nothing to keep warm.
            guard let storeURL = PAgentSchema.sharedStoreURL() else {
                // The App Group is not provisioned. Failing loudly beats
                // falling back to a private-container store: that would
                // silently split the log in two and present later as "shared
                // items sometimes vanish".
                return .storeUnavailable("共享容器不可用，请检查 App Group 配置")
            }

            let container = try PAgentSchema.container(url: storeURL)
            let context = ModelContext(container)
            context.insert(SignalEvent(try SignalRecord.capture(captured)))
            try context.save()
            return .saved
        } catch {
            return .storeUnavailable(error.localizedDescription)
        }
    }

    /// Pulls a URL or text out of the extension's input items.
    ///
    /// A share can carry both — most browsers attach the page URL *and* the
    /// title or selection — so both are kept when present. The URL is the
    /// more durable of the two (it can be re-fetched later; a title cannot be
    /// recovered), so a share with only text is still accepted but a share
    /// with neither is not.
    private func extractSharedContent() async -> SignalPayload? {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []

        var url: URL?
        var text: String?

        for item in items {
            for provider in item.attachments ?? [] {
                if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    url = try? await provider.loadItem(
                        forTypeIdentifier: UTType.url.identifier
                    ) as? URL
                }
                if text == nil, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    text = try? await provider.loadItem(
                        forTypeIdentifier: UTType.plainText.identifier
                    ) as? String
                }
            }
            // The attributed content text is what Safari puts a page title or
            // a user's selection into; it is often the only human-readable
            // part of a share.
            if text == nil, let contentText = item.attributedContentText?.string,
                !contentText.isEmpty
            {
                text = contentText
            }
        }

        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard url != nil || !trimmed.isEmpty else { return nil }

        return .shared(url: url, text: trimmed, sharedAt: .now)
    }

    // MARK: - Presentation

    private func present(_ outcome: Outcome) {
        let view = ShareResultView(outcome: outcome) { [weak self] in
            self?.finish(outcome)
        }
        let host = UIHostingController(rootView: view)
        host.view.backgroundColor = .clear

        addChild(host)
        host.view.frame = self.view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    private func finish(_ outcome: Outcome) {
        switch outcome {
        case .saved, .nothingUsable:
            extensionContext?.completeRequest(returningItems: [])
        case .storeUnavailable(let message):
            // Cancelling rather than completing tells the host app the share
            // did not happen, so the user is not left believing it was saved.
            extensionContext?.cancelRequest(
                withError: NSError(
                    domain: "com.example.PAgent.ShareExtension",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            )
        }
    }

    private struct ShareResultView: View {
        let outcome: Outcome
        let dismiss: () -> Void

        private var title: String {
            switch outcome {
            case .saved: "已存入 PAgent"
            case .nothingUsable: "没有可保存的内容"
            case .storeUnavailable: "保存失败"
            }
        }

        private var detail: String {
            switch outcome {
            case .saved:
                "今晚整理时会用它更新你的兴趣画像。内容只保存在这台设备上。"
            case .nothingUsable:
                "这次分享里没有链接或文字。"
            case .storeUnavailable(let message):
                message
            }
        }

        var body: some View {
            VStack(spacing: 12) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("好", action: dismiss)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.2))
        }
    }
}
