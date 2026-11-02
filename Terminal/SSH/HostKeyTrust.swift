import Foundation
import CryptoKit
import NIO
import NIOSSH

/// Thrown when the user (or policy) rejects the presented host key.
struct UntrustedHostKey: Error, Sendable {}

enum HostKeyEvent: Equatable, Sendable {
    case unknown(host: String, port: Int, keyLine: String, fingerprint: String)
    case changed(host: String, port: Int, keyLine: String, expectedFingerprint: String, fingerprint: String)
}

/// TOFU (trust-on-first-use) host key validator. Known keys are verified
/// against the store; unknown or changed keys are delegated to an async
/// decider (UI alert) without blocking the event loop.
final class HostKeyTrustValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private let host: String
    private let port: Int
    private let knownKey: String?
    private let decide: @Sendable (HostKeyEvent) async -> Bool

    init(host: String, port: Int, knownKey: String?, decide: @escaping @Sendable (HostKeyEvent) async -> Bool) {
        self.host = host
        self.port = port
        self.knownKey = knownKey
        self.decide = decide
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey)

        if let known = knownKey {
            if known == line {
                validationCompletePromise.succeed(())
            } else {
                let event = HostKeyEvent.changed(
                    host: host, port: port,
                    keyLine: line,
                    expectedFingerprint: Self.fingerprint(of: known),
                    fingerprint: Self.fingerprint(of: line)
                )
                Task {
                    if await decide(event) {
                        validationCompletePromise.succeed(())
                    } else {
                        validationCompletePromise.fail(UntrustedHostKey())
                    }
                }
            }
            return
        }

        let event = HostKeyEvent.unknown(
            host: host, port: port,
            keyLine: line,
            fingerprint: Self.fingerprint(of: line)
        )
        Task {
            if await decide(event) {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(UntrustedHostKey())
            }
        }
    }

    /// OpenSSH-style "SHA256:base64" fingerprint (padding stripped).
    static func fingerprint(of keyLine: String) -> String {
        guard let b64 = keyLine.split(separator: " ").dropFirst().first,
              let blob = Data(base64Encoded: String(b64)) else {
            return keyLine
        }
        let digest = SHA256.hash(data: blob)
        return "SHA256:" + Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}
