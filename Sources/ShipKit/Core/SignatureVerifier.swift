import CryptoKit
import Foundation

/// Verifies snapshot signatures made with the project's Ed25519 key.
///
/// `X-ShipKit-Signature-V2` covers the install ID, the exact request bytes and the exact response
/// body, so a response can't be replayed or passed off as the answer to an edited request.
/// `X-ShipKit-Signature` (response body only) is what SDK 1.1 and earlier checked.
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

    /// Checks a V2 signature against the request that was really sent and the body that was received.
    public func isValid(signature base64Signature: String?, stableID: String, requestBody: Data, responseBody: Data) -> Bool {
        isValid(signature: base64Signature, for: Self.signingInput(stableID: stableID, requestBody: requestBody, responseBody: responseBody))
    }

    static func signingInput(stableID: String, requestBody: Data, responseBody: Data) -> Data {
        Data("shipkit-snapshot-v2\n\(stableID.lowercased())\n\(hex(requestBody))\n\(hex(responseBody))".utf8)
    }

    private static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
