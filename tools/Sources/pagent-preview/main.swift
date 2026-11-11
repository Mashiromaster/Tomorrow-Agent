import CryptoKit
import Foundation
import SwiftUI

import PAgentCore
import PAgentNet

// A macOS window running the real `PlannerView`.
//
//     cd proxy && npx wrangler dev --local      # one terminal
//     cd tools && swift run pagent-preview      # another
//
// `PlannerView.swift` here is a symlink to `ios/App/PlannerView.swift`, not a
// copy — see Package.swift for why that file can build on macOS at all.

// MARK: - Configuration

/// Where the proxy lives, and how to reach it.
///
/// `PlannerView` reads this through `ProxyConfiguration`, which on iOS comes
/// from `Info.plist`. There is no bundle here, so the harness takes it from
/// the environment instead — same contract, different source.
enum ProxyConfiguration {
    static var baseURL: URL? {
        let raw = ProcessInfo.processInfo.environment["PAGENT_PROXY_URL"]
            ?? "http://127.0.0.1:8787"
        return raw.isEmpty ? nil : URL(string: raw)
    }
}

// MARK: - Device token

/// Signs a device token with the deployment's own `JWT_SIGNING_KEY`.
///
/// Stands in for App Attest, which needs a provisioned device. Mirrors
/// `proxy/scripts/verify-cache.mjs`, which mirrors `proxy/src/jwt.ts`. This
/// exercises the proxy's *verification* path and proves nothing about
/// attestation — that layer has its own 24 tests and can only be confirmed on
/// hardware.
struct LocalTokenProvider: DeviceTokenProviding {
    let secret: String
    let deviceID: String

    func token() async throws -> DeviceToken { signed() }
    func refreshedToken() async throws -> DeviceToken { signed() }

    private func signed(lifetime: TimeInterval = 900) -> DeviceToken {
        let issuedAt = Date()
        let expiresAt = issuedAt.addingTimeInterval(lifetime)

        let header = base64url(["alg": "HS256", "typ": "JWT"])
        let claims = base64url([
            "sub": deviceID,
            "iat": Int(issuedAt.timeIntervalSince1970),
            "exp": Int(expiresAt.timeIntervalSince1970),
            "tier": "free",
        ])
        let input = "\(header).\(claims)"
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(input.utf8),
            using: SymmetricKey(data: Data(secret.utf8))
        )
        return DeviceToken(value: "\(input).\(base64url(Data(mac)))", expiresAt: expiresAt)
    }

    private func base64url(_ json: [String: Any]) -> String {
        base64url(try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
    }

    private func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Reads `JWT_SIGNING_KEY` from the environment, falling back to
/// `proxy/.dev.vars` — the same order the two verification scripts use, so all
/// three tools cannot disagree about which deployment they are talking to.
func signingKey() -> String? {
    if let fromEnvironment = ProcessInfo.processInfo.environment["JWT_SIGNING_KEY"],
        !fromEnvironment.isEmpty
    {
        return fromEnvironment
    }

    let devVars = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .deletingLastPathComponent()
        .appendingPathComponent("proxy/.dev.vars")
    guard let contents = try? String(contentsOf: devVars, encoding: .utf8) else { return nil }

    for line in contents.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("JWT_SIGNING_KEY"), let equals = trimmed.firstIndex(of: "=") else {
            continue
        }
        let value = trimmed[trimmed.index(after: equals)...]
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if !value.isEmpty { return value }
    }
    return nil
}

// MARK: - App

@main
struct PreviewApp: App {
    private let secret = signingKey()

    var body: some Scene {
        WindowGroup("PAgent — macOS 预览") {
            Group {
                if let secret {
                    NavigationStack {
                        PlannerView(
                            tokenProvider: { _ in
                                LocalTokenProvider(secret: secret, deviceID: "macos-preview")
                            },
                            // `--prompt "…"` sends one turn at launch. Exists
                            // so the window can be screenshotted mid-stream
                            // without driving the keyboard, which needs
                            // Accessibility permission and steals focus from
                            // whatever else is open.
                            initialPrompt: ProcessInfo.processInfo.arguments
                                .firstIndex(of: "--prompt")
                                .flatMap { i in
                                    ProcessInfo.processInfo.arguments.dropFirst(i + 1).first
                                }
                        )
                    }
                } else {
                    MissingKeyView()
                }
            }
            .frame(minWidth: 520, minHeight: 640)
        }
        .windowResizability(.contentSize)
    }
}

/// Shown when no signing key is available.
///
/// A real screen rather than a crash, for the same reason `StartupFailureView`
/// exists on iOS: this is a configuration problem, and the fix depends on
/// knowing which one it is.
private struct MissingKeyView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.slash")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("找不到 JWT_SIGNING_KEY")
                .font(.headline)
            Text(
                """
                预览需要一个签名密钥来铸造设备 token（代替真机上的 App Attest）。

                本地代理：`cp proxy/.dev.vars.example proxy/.dev.vars` 并填好，
                然后从仓库根目录运行。

                线上部署：密钥是 `wrangler secret put` 写进去的，读不回来——
                轮换一把新的并通过环境变量传入。
                """
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 420)
        }
        .padding(40)
    }
}
