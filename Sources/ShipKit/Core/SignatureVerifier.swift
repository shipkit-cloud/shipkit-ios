import CryptoKit
import Foundation

/// Verifies `X-ShipKit-Signature` (base64 Ed25519 over the exact response body bytes).
public struct SignatureVerifier: Sendable {
    private let key: Curve25519.Signing.PublicKey

    /// - Parameter base64PublicKey: base64 of the raw 32-byte public key.
    public init?(base64PublicKey: String) {
        guard let raw = Data(base64Encoded: base64PublicKey.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return nil }
        self.key = key
    }

    public func isValid(signature base64Signature: String?, for body: Data) -> Bool {
        guard let base64Signature,
              let signature = Data(base64Encoded: base64Signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              signature.count == 64 else { return false }
        return key.isValidSignature(signature, for: body)
    }
}
