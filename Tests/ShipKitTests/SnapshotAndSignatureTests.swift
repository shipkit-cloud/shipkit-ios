import CryptoKit
import XCTest
@testable import ShipKit

final class SnapshotDecodingTests: XCTestCase {
    func testDecodesDocumentedSample() throws {
        let data = try XCTUnwrap(TestEnv.fixture("snapshot-sample", ext: "json"), "Fixtures/snapshot-sample.json missing")
        let snapshot = try ShipKitSnapshot(jsonData: data)

        XCTAssertEqual(snapshot.release, 7)
        XCTAssertEqual(snapshot.ttl, 900)
        XCTAssertEqual(snapshot.settings["max_upload_mb"], .int(25))
        XCTAssertEqual(snapshot.settings["promo_banner"], .string("Hello"))
        XCTAssertEqual(snapshot.settings["limits"], .object(["a": .int(1)]))
        XCTAssertEqual(snapshot.flags["new_onboarding"], .bool(true))
        XCTAssertEqual(snapshot.flags["paywall_layout"], .string("B"))
        XCTAssertEqual(snapshot.inbox?.unread, 1)

        let version = try XCTUnwrap(snapshot.version)
        XCTAssertEqual(version.status, .ok)
        XCTAssertEqual(version.current, "2.4.0")
        XCTAssertEqual(version.min, "2.0.0")
        XCTAssertEqual(version.recommended, "2.5.0")
        XCTAssertEqual(version.latest, "2.5.1")
        XCTAssertEqual(version.storeURL, URL(string: "https://apps.apple.com/app/id123456789"))
        XCTAssertEqual(version.title, "New version available")
        XCTAssertEqual(version.message, "Faster sync and bug fixes.")
        XCTAssertEqual(version.reminder, .init(everyLaunches: 3, everyDays: 2, maxPerVersion: 3, allowSkip: true))
        XCTAssertNil(version.maintenance)
        XCTAssertNil(version.osFloor)
        XCTAssertEqual(version.whatsNew, .init(version: "2.4.0", items: ["Dark mode", "Faster sync"]))
        XCTAssertEqual(version.personal, ["The issue you reported is fixed in 2.5.0."])
        XCTAssertEqual(version.targetVersion, "2.5.0")
    }

    func testDecodesMaintenanceAndToleratesUnknownValues() throws {
        let json = Data("""
        {"release":3,"settings":{},"flags":{},
         "version":{"status":"maintenance","maintenance":{"message":"Upgrading","until":"2026-11-15T10:00:00.250Z"},
                    "osFloor":{"minOS":"17.0","message":"Requires iOS 17"},"storeURL":"","futureField":1},
         "futureTopLevel":{"x":1}}
        """.utf8)
        let snapshot = try ShipKitSnapshot(jsonData: json)
        XCTAssertEqual(snapshot.version?.status, .maintenance)
        XCTAssertEqual(snapshot.version?.maintenance?.message, "Upgrading")
        XCTAssertEqual(snapshot.version?.maintenance?.until, ISO8601.date(from: "2026-11-15T10:00:00.250Z"))
        XCTAssertNotNil(snapshot.version?.maintenance?.until)
        XCTAssertEqual(snapshot.version?.osFloor?.minOS, "17.0")
        XCTAssertNil(snapshot.version?.storeURL)
        XCTAssertNil(snapshot.inbox)

        let unknownStatus = try ShipKitSnapshot(jsonData: Data(#"{"version":{"status":"sunset"}}"#.utf8))
        XCTAssertEqual(unknownStatus.version?.status, .ok)
    }

    func testDatesWithAndWithoutFractionalSeconds() {
        XCTAssertNotNil(ISO8601.date(from: "2026-11-15T10:00:00Z"))
        XCTAssertNotNil(ISO8601.date(from: "2026-11-15T10:00:00.123Z"))
        XCTAssertNil(ISO8601.date(from: "15/11/2026"))
    }

    func testTypedSettingDecoding() {
        struct Limits: Decodable, Equatable { let a: Int }
        let value: ShipKitValue = ["a": 1]
        XCTAssertEqual(value.decode(Limits.self), Limits(a: 1))
        XCTAssertEqual(ShipKitValue.int(25).decode(Double.self), 25)
        XCTAssertEqual(ShipKitValue.double(25).decode(Int.self), 25)
        XCTAssertNil(ShipKitValue.string("25").decode(Int.self))
        XCTAssertNil(ShipKitValue.int(1).decode(Bool.self))
        XCTAssertEqual(ShipKitValue.parse("{\"a\": [1, true]}"), ["a": [1, true]])
        XCTAssertEqual(ShipKitValue.parse("hello"), "hello")
    }

    @MainActor
    func testConfigureForTesting() {
        ShipKit.configureForTesting(snapshot: ShipKitSnapshot(
            settings: ["max_upload_mb": 40, "promo_banner": "Hi", "limits": ["a": 2]],
            flags: ["new_onboarding": true, "paywall_layout": "B"],
            version: VersionInfo(status: .recommended, recommended: "9.0.0"),
            unreadCount: 3
        ))
        XCTAssertEqual(ShipKit.setting("max_upload_mb", default: 25), 40)
        XCTAssertEqual(ShipKit.setting("max_upload_mb", default: 25.0), 40.0)
        XCTAssertEqual(ShipKit.setting("promo_banner", default: ""), "Hi")
        XCTAssertEqual(ShipKit.setting("promo_banner", default: 0), 0, "type mismatch falls back to default")
        XCTAssertEqual(ShipKit.setting("missing", default: "x"), "x")
        XCTAssertEqual(ShipKit.setting("limits", default: ShipKitValue.null)["a"], .int(2))
        XCTAssertTrue(ShipKit.isEnabled("new_onboarding"))
        XCTAssertFalse(ShipKit.isEnabled("unknown_flag"))
        XCTAssertEqual(ShipKit.variant("paywall_layout", default: "control"), "B")
        XCTAssertEqual(ShipKit.variant("unknown_flag", default: "control"), "control")
        guard case .updateRecommended = ShipKit.currentVersionStatus else { return XCTFail("expected recommended") }
    }

    func testAPIURLOverride() {
        let defaults = UserDefaults(suiteName: "ShipKitTests-\(UUID().uuidString)")!
        XCTAssertNil(ShipKit.apiURLOverride(environment: [:], defaults: defaults))
        XCTAssertEqual(
            ShipKit.apiURLOverride(environment: ["SHIPKIT_API_URL": "http://localhost:8787"], defaults: defaults),
            URL(string: "http://localhost:8787")
        )
        defaults.set("http://127.0.0.1:9000", forKey: ShipKitDefaults.apiURLDefaultsKey)
        XCTAssertEqual(ShipKit.apiURLOverride(environment: [:], defaults: defaults), URL(string: "http://127.0.0.1:9000"))
    }
}

final class SignatureTests: XCTestCase {
    private struct Vector: Decodable {
        let publicKey: String
        let body: String
        let signature: String
    }

    /// Vector produced by the backend's WebCrypto Ed25519 implementation.
    func testBackendSignatureVector() throws {
        guard let data = TestEnv.fixture("signature-vector", ext: "json") else {
            throw XCTSkip("Fixtures/signature-vector.json not present")
        }
        let vector = try JSONDecoder().decode(Vector.self, from: data)
        let verifier = try XCTUnwrap(SignatureVerifier(base64PublicKey: vector.publicKey))
        let body = Data(vector.body.utf8)

        XCTAssertTrue(verifier.isValid(signature: vector.signature, for: body))

        var tampered = body
        tampered[tampered.startIndex] ^= 0x01
        XCTAssertFalse(verifier.isValid(signature: vector.signature, for: tampered))
        XCTAssertFalse(verifier.isValid(signature: nil, for: body))
        XCTAssertFalse(verifier.isValid(signature: "not base64", for: body))

        XCTAssertNoThrow(try ShipKitSnapshot(jsonData: body), "signed body is a valid snapshot")
    }

    func testCryptoKitRoundTrip() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let body = Data(#"{"release":1,"settings":{"greeting":"Hej 👋"}}"#.utf8)
        let signature = try privateKey.signature(for: body).base64EncodedString()

        let verifier = try XCTUnwrap(SignatureVerifier(base64PublicKey: publicKey))
        XCTAssertTrue(verifier.isValid(signature: signature, for: body))
        XCTAssertFalse(verifier.isValid(signature: signature, for: body + Data(" ".utf8)))

        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertFalse(try XCTUnwrap(SignatureVerifier(base64PublicKey: otherKey)).isValid(signature: signature, for: body))
    }

    func testInvalidPublicKeyIsRejected() {
        XCTAssertNil(SignatureVerifier(base64PublicKey: "short"))
        XCTAssertNil(SignatureVerifier(base64PublicKey: Data(repeating: 1, count: 16).base64EncodedString()))
    }
}
