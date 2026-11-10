import CryptoKit
import DeviceCheck
import Foundation
import Security

import PAgentNet

/// Mints device tokens by performing the §2.3 App Attest handshake.
///
/// ## Verification status
///
/// **Every path in this file is unexercised.** `DCAppAttestService` requires a
/// provisioned device — it is unavailable in the simulator and returns
/// `invalidKey` without a real App ID — so none of this can run here, and
/// there are no tests for it. Treat it as a reviewed first draft.
///
/// What *is* tested is everything around it: the caching and single-flight
/// policy in ``PAgentNet/CachingDeviceTokenProvider``, and the retry and
/// error-mapping behaviour in ``PAgentNet/ProxyTransport``. This type is
/// deliberately the thinnest possible shim between those and Apple's API, for
/// the same reason ``PAgentNet/URLSessionByteStreaming`` is thin: code that
/// cannot be tested should not also contain the decisions.
///
/// ## The handshake
///
/// ```
///  first run    POST /v1/attest/challenge  → challenge
///               generateKey()              → keyId   (Secure Enclave)
///               attestKey(keyId, hash)     → attestation
///               POST /v1/attest            → enrolled
///
///  every token  POST /v1/token/challenge   → challenge
///               generateAssertion(keyId)   → assertion
///               POST /v1/token             → 15-minute JWT
/// ```
///
/// The device never holds an Anthropic API key (§2.3) — only a Secure Enclave
/// key that yields short-lived proxy tokens.
public actor AppAttestTokenProvider {
    public enum AttestationError: Error, LocalizedError {
        /// No Apple Intelligence-independent hardware requirement here —
        /// App Attest needs a real device with a Secure Enclave.
        case unsupportedDevice
        case challengeFailed(status: Int)
        case enrollmentFailed(status: Int, message: String)
        case tokenExchangeFailed(status: Int, message: String)
        case malformedResponse(String)
        case keychain(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .unsupportedDevice:
                "这台设备不支持 App Attest（模拟器不支持，需要真机）。"
            case .challengeFailed(let status):
                "无法从代理获取挑战（HTTP \(status)）。"
            case .enrollmentFailed(_, let message):
                "设备注册失败：\(message)"
            case .tokenExchangeFailed(_, let message):
                "获取访问令牌失败：\(message)"
            case .malformedResponse(let detail):
                "代理返回了无法解析的响应：\(detail)"
            case .keychain(let status):
                "Keychain 操作失败（\(status)）。"
            }
        }
    }

    private let baseURL: URL
    private let http: any HTTPByteStreaming
    private let service: DCAppAttestService
    private let keyStore: AttestKeyStore

    public init(
        baseURL: URL,
        http: any HTTPByteStreaming = URLSessionByteStreaming(),
        keyStore: AttestKeyStore = KeychainAttestKeyStore()
    ) {
        self.baseURL = baseURL
        self.http = http
        self.service = DCAppAttestService.shared
        self.keyStore = keyStore
    }

    /// A ``PAgentNet/DeviceTokenProviding`` wired to this provider.
    ///
    /// The caching policy lives in `PAgentNet` where it is tested; this only
    /// supplies the mint operation.
    public func tokenProvider() -> CachingDeviceTokenProvider {
        CachingDeviceTokenProvider { [self] in
            try await mintToken()
        }
    }

    // MARK: - Handshake

    /// Produces a fresh device token, enrolling the device first if needed.
    public func mintToken() async throws -> DeviceToken {
        guard service.isSupported else { throw AttestationError.unsupportedDevice }

        let keyID = try await enrolledKeyID()

        let challenge = try await fetchChallenge(path: "v1/token/challenge")
        let clientDataHash = Data(SHA256.hash(data: Data(challenge.utf8)))
        let assertion = try await generateAssertion(keyID: keyID, clientDataHash: clientDataHash)

        let response = try await postJSON(
            path: "v1/token",
            payload: [
                "key_id": keyID,
                "assertion": assertion.base64EncodedString(),
                "challenge": challenge,
            ]
        )

        guard response.isSuccess else {
            throw AttestationError.tokenExchangeFailed(
                status: response.status,
                message: try await errorMessage(from: response)
            )
        }

        struct TokenReply: Decodable {
            let token: String
            let expiresAt: TimeInterval

            private enum CodingKeys: String, CodingKey {
                case token
                case expiresAt = "expires_at"
            }
        }

        let body = try await response.collect()
        guard let reply = try? JSONDecoder().decode(TokenReply.self, from: body) else {
            throw AttestationError.malformedResponse("token response")
        }

        return DeviceToken(
            value: reply.token,
            expiresAt: Date(timeIntervalSince1970: reply.expiresAt)
        )
    }

    /// The enrolled key, enrolling once if this is a first run.
    ///
    /// The keyId is cached in the Keychain rather than re-derived: the proxy
    /// refuses to enroll a keyId twice (that would reset its replay counter),
    /// so generating a new key on every launch would mean a device that can
    /// never authenticate after the first time.
    private func enrolledKeyID() async throws -> String {
        if let existing = try keyStore.loadKeyID() { return existing }

        let keyID = try await generateKey()
        let challenge = try await fetchChallenge(path: "v1/attest/challenge")
        let clientDataHash = Data(SHA256.hash(data: Data(challenge.utf8)))
        let attestation = try await attestKey(keyID: keyID, clientDataHash: clientDataHash)

        let response = try await postJSON(
            path: "v1/attest",
            payload: [
                "key_id": keyID,
                "attestation": attestation.base64EncodedString(),
                "challenge": challenge,
            ]
        )

        guard response.isSuccess else {
            // The key is not persisted on failure. A keyId the proxy never
            // accepted is worse than no key: the next launch would skip
            // enrolment and fail every token exchange forever.
            throw AttestationError.enrollmentFailed(
                status: response.status,
                message: try await errorMessage(from: response)
            )
        }

        try keyStore.saveKeyID(keyID)
        return keyID
    }

    // MARK: - Proxy calls

    private func fetchChallenge(path: String) async throws -> String {
        let response = try await postJSON(path: path, payload: nil)
        guard response.isSuccess else {
            throw AttestationError.challengeFailed(status: response.status)
        }

        struct ChallengeReply: Decodable {
            let challenge: String
        }

        let body = try await response.collect()
        guard let reply = try? JSONDecoder().decode(ChallengeReply.self, from: body) else {
            throw AttestationError.malformedResponse("challenge response")
        }
        return reply.challenge
    }

    private func postJSON(
        path: String,
        payload: [String: String]?
    ) async throws -> StreamingResponse {
        // `[String: String]` always encodes, so this cannot fail in practice —
        // but a force-try here would crash the app rather than surface a
        // recoverable enrolment failure if that ever stopped being true.
        let body: Data
        if let payload {
            guard let encoded = try? JSONEncoder().encode(payload) else {
                throw AttestationError.malformedResponse("could not encode the request")
            }
            body = encoded
        } else {
            body = Data()
        }

        return try await http.stream(
            url: baseURL.appendingPathComponent(path),
            method: "POST",
            headers: ["content-type": "application/json"],
            body: body
        )
    }

    private func errorMessage(from response: StreamingResponse) async throws -> String {
        struct Envelope: Decodable {
            struct Payload: Decodable { let message: String }
            let error: Payload
        }
        let body = (try? await response.collect()) ?? Data()
        return (try? JSONDecoder().decode(Envelope.self, from: body))?.error.message
            ?? "HTTP \(response.status)"
    }

    // MARK: - DeviceCheck bridging

    private func generateKey() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            service.generateKey { keyID, error in
                if let keyID {
                    continuation.resume(returning: keyID)
                } else {
                    continuation.resume(throwing: error ?? AttestationError.unsupportedDevice)
                }
            }
        }
    }

    private func attestKey(keyID: String, clientDataHash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            service.attestKey(keyID, clientDataHash: clientDataHash) { attestation, error in
                if let attestation {
                    continuation.resume(returning: attestation)
                } else {
                    continuation.resume(throwing: error ?? AttestationError.unsupportedDevice)
                }
            }
        }
    }

    private func generateAssertion(keyID: String, clientDataHash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            service.generateAssertion(keyID, clientDataHash: clientDataHash) { assertion, error in
                if let assertion {
                    continuation.resume(returning: assertion)
                } else {
                    continuation.resume(throwing: error ?? AttestationError.unsupportedDevice)
                }
            }
        }
    }
}

// MARK: - Key storage

/// Persists the App Attest keyId.
///
/// A protocol so the enrolment flow can be exercised without a Keychain —
/// the interesting logic is "do not persist a keyId the proxy rejected", and
/// that is worth a test once there is a device to run the rest against.
public protocol AttestKeyStore: Sendable {
    func loadKeyID() throws -> String?
    func saveKeyID(_ keyID: String) throws
    func deleteKeyID() throws
}

/// Keychain-backed storage.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: the nightly digest
/// (§6.1) runs as a background task while the phone is locked, so the keyId
/// has to be readable then — but `ThisDeviceOnly` keeps it out of backups,
/// because a keyId restored onto a second device would not match that
/// device's Secure Enclave key and would fail every assertion.
public struct KeychainAttestKeyStore: AttestKeyStore {
    private let account = "com.example.PAgent.appattest.keyid"

    public init() {}

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
    }

    public func loadKeyID() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let keyID = String(data: data, encoding: .utf8) else {
                return nil
            }
            return keyID
        case errSecItemNotFound:
            return nil
        default:
            throw AppAttestTokenProvider.AttestationError.keychain(status)
        }
    }

    public func saveKeyID(_ keyID: String) throws {
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(keyID.utf8)
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = [kSecValueData as String: Data(keyID.utf8)]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw AppAttestTokenProvider.AttestationError.keychain(updateStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw AppAttestTokenProvider.AttestationError.keychain(status)
        }
    }

    public func deleteKeyID() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppAttestTokenProvider.AttestationError.keychain(status)
        }
    }
}
