import CryptoKit
import XCTest
@testable import ShipKit

final class EngineTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    // MARK: - Fail-open matrix

    func testNoNetworkNoCacheNeverBlocks() async {
        MockURLProtocol.setHandler(nil)
        let engine = TestEnv.makeEngine(directory: TestEnv.directory())
        let status = await engine.versionStatus()
        XCTAssertEqual(status, .ok)
        XCTAssertNil(engine.snapshot)
        XCTAssertEqual(engine.settingValue("max_upload_mb"), nil)
    }

    func testCachedBlockStaysEnforcedOffline() async {
        let directory = TestEnv.directory()
        let preferences = TestEnv.preferences()
        MockURLProtocol.setHandler { _ in MockResponse(status: 200, headers: ["ETag": "\"v1\""], body: TestEnv.snapshotJSON(status: "blocked")) }
        let online = TestEnv.makeEngine(directory: directory, preferences: preferences)
        await online.refresh()
        guard case .blocked = online.currentVersionStatus else { return XCTFail("expected blocked online") }

        MockURLProtocol.setHandler(nil)
        let offline = TestEnv.makeEngine(directory: directory, preferences: preferences)
        guard case .blocked = offline.currentVersionStatus else { return XCTFail("cached block must apply before any refresh") }
        let status = await offline.versionStatus()
        guard case .blocked = status else { return XCTFail("cached block must survive a failed refresh") }
        XCTAssertNotNil(offline.lastError)
    }

    func testCachedMaintenanceAndRequiredStayEnforcedOffline() async {
        for status in ["maintenance", "required"] {
            let directory = TestEnv.directory()
            MockURLProtocol.setHandler { _ in MockResponse(status: 200, body: TestEnv.snapshotJSON(status: status)) }
            await TestEnv.makeEngine(directory: directory).refresh()
            MockURLProtocol.setHandler(nil)
            let result = await TestEnv.makeEngine(directory: directory).versionStatus()
            XCTAssertTrue(result.isBlocking, "\(status) should stay enforced offline")
        }
    }

    func testCachedOKStaysOKOffline() async {
        let directory = TestEnv.directory()
        MockURLProtocol.setHandler { _ in MockResponse(status: 200, body: TestEnv.snapshotJSON(status: "ok")) }
        await TestEnv.makeEngine(directory: directory).refresh()

        MockURLProtocol.setHandler(nil)
        let offline = TestEnv.makeEngine(directory: directory)
        let status = await offline.versionStatus()
        XCTAssertEqual(status, .ok)
        XCTAssertEqual(offline.settingValue("max_upload_mb"), .int(50), "cached values are served offline")
        XCTAssertTrue(offline.isEnabled("new_onboarding"))
    }

    func testCachedRequiredLiftedAfterAppUpdate() async {
        let directory = TestEnv.directory()
        MockURLProtocol.setHandler { _ in MockResponse(status: 200, body: TestEnv.snapshotJSON(status: "required")) }
        await TestEnv.makeEngine(directory: directory, appVersion: "1.9.0").refresh()
        MockURLProtocol.setHandler(nil)
        let updated = TestEnv.makeEngine(directory: directory, appVersion: "2.5.1", build: "400")
        XCTAssertEqual(updated.currentVersionStatus, .ok)
    }

    // MARK: - Value resolution

    func testValueResolutionOrder() async {
        let directory = TestEnv.directory()
        let engine = TestEnv.makeEngine(directory: directory) { options in
            options.defaults = ["max_upload_mb": 10, "only_default": "fallback"]
        }
        XCTAssertEqual(engine.settingValue("max_upload_mb"), .int(10), "bundled default before any snapshot")

        MockURLProtocol.setHandler { _ in MockResponse(status: 200, body: TestEnv.snapshotJSON(status: "ok")) }
        await engine.refresh()
        XCTAssertEqual(engine.settingValue("max_upload_mb"), .int(50), "snapshot wins over defaults")
        XCTAssertEqual(engine.settingValue("only_default"), .string("fallback"), "defaults fill gaps")

        engine.setOverride(setting: "max_upload_mb", value: 99)
        XCTAssertEqual(engine.settingValue("max_upload_mb"), .int(99), "local override wins")
        engine.setOverride(setting: "max_upload_mb", value: nil)
        XCTAssertEqual(engine.settingValue("max_upload_mb"), .int(50))
    }

    func testLockFlagsOnLaunchKeepsSessionValues() async {
        let directory = TestEnv.directory()
        let preferences = TestEnv.preferences()
        MockURLProtocol.setHandler { _ in MockResponse(status: 200, body: TestEnv.snapshotJSON(status: "ok")) }
        await TestEnv.makeEngine(directory: directory, preferences: preferences).refresh()

        let locked = TestEnv.makeEngine(directory: directory, preferences: preferences) { $0.lockFlagsOnLaunch = true }
        let newer = Data(#"{"release":2,"settings":{"max_upload_mb":75},"flags":{"new_onboarding":false}}"#.utf8)
        MockURLProtocol.setHandler { _ in MockResponse(status: 200, body: newer) }
        await locked.refresh()
        XCTAssertEqual(locked.snapshot?.release, 2)
        XCTAssertEqual(locked.settingValue("max_upload_mb"), .int(50))
        XCTAssertTrue(locked.isEnabled("new_onboarding"))
    }

    // MARK: - Protocol details

    func testRequestHeadersAndContext() async throws {
        MockURLProtocol.setHandler { _ in MockResponse(status: 200, body: TestEnv.snapshotJSON(status: "ok")) }
        let engine = TestEnv.makeEngine(directory: TestEnv.directory())
        await engine.refresh()

        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://api.test/v1/snapshot")
        XCTAssertEqual(request.headers["Authorization"], "Bearer skc_test")
        XCTAssertEqual(request.headers["X-ShipKit-Stable-Id"], engine.stableID)
        XCTAssertEqual(engine.stableID, engine.stableID.lowercased())
        XCTAssertNotNil(UUID(uuidString: engine.stableID))
        XCTAssertEqual(request.headers["X-ShipKit-SDK"], "ios/\(ShipKit.sdkVersion)")
        XCTAssertEqual(request.headers["X-Bundle-Id"], "dev.shipkit.tests")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")

        let body = try XCTUnwrap(request.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["platform"] as? String, "ios")
        XCTAssertEqual(json["appVersion"] as? String, "2.4.0")
        XCTAssertEqual(json["build"] as? String, "311")
        XCTAssertEqual(json["stableId"] as? String, engine.stableID)
        XCTAssertNotNil(json["device"] as? String)
        XCTAssertNotNil(json["osVersion"] as? String)
    }

    func testSimulatedVersionIsSentAsAppVersion() async throws {
        let preferences = TestEnv.preferences()
        preferences.defaults.set("1.0.0", forKey: ShipKitDefaults.simulatedVersionKey)
        MockURLProtocol.setHandler { _ in MockResponse(status: 200, body: TestEnv.snapshotJSON(status: "required")) }
        let engine = TestEnv.makeEngine(directory: TestEnv.directory(), preferences: preferences)
        await engine.refresh()
        let body = try XCTUnwrap(MockURLProtocol.requests.first?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["appVersion"] as? String, "1.0.0")
        guard case .updateRequired = engine.currentVersionStatus else { return XCTFail("expected required") }
    }

    func testETagAndNotModifiedKeepsCache() async throws {
        let directory = TestEnv.directory()
        MockURLProtocol.setHandler { _ in MockResponse(status: 200, headers: ["ETag": "\"abc\""], body: TestEnv.snapshotJSON(status: "ok")) }
        let engine = TestEnv.makeEngine(directory: directory) { $0.signingKey = nil }
        await engine.refresh()

        MockURLProtocol.setHandler { request in
            request.headers["If-None-Match"] == "\"abc\"" ? MockResponse(status: 304) : MockResponse(status: 500)
        }
        await engine.refresh()
        XCTAssertEqual(MockURLProtocol.requests.first?.headers["If-None-Match"], "\"abc\"")
        XCTAssertNil(engine.lastError)
        XCTAssertEqual(engine.settingValue("max_upload_mb"), .int(50))
        XCTAssertEqual(engine.meta?.etag, "\"abc\"")
    }

    func testNotModifiedWithoutSignatureIsAcceptedWhenSigningEnabled() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let body = TestEnv.snapshotJSON(status: "ok")
        let signature = try key.signature(for: body).base64EncodedString()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()

        MockURLProtocol.setHandler { _ in MockResponse(status: 200, headers: ["ETag": "\"s1\"", "X-ShipKit-Signature": signature], body: body) }
        let engine = TestEnv.makeEngine(directory: TestEnv.directory()) { $0.signingKey = publicKey }
        await engine.refresh()
        XCTAssertEqual(engine.snapshot?.release, 1)

        MockURLProtocol.setHandler { _ in MockResponse(status: 304) }
        await engine.refresh()
        XCTAssertNil(engine.lastError)
        XCTAssertEqual(engine.snapshot?.release, 1)
    }

    func testRejectsTamperedOrUnsignedSnapshotWhenSigningEnabled() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let good = TestEnv.snapshotJSON(status: "ok")
        let goodSignature = try key.signature(for: good).base64EncodedString()

        let directory = TestEnv.directory()
        MockURLProtocol.setHandler { _ in MockResponse(status: 200, headers: ["X-ShipKit-Signature": goodSignature], body: good) }
        let engine = TestEnv.makeEngine(directory: directory) { $0.signingKey = publicKey }
        await engine.refresh()
        XCTAssertEqual(engine.settingValue("max_upload_mb"), .int(50))

        let tampered = TestEnv.snapshotJSON(status: "blocked")
        MockURLProtocol.setHandler { _ in MockResponse(status: 200, headers: ["X-ShipKit-Signature": goodSignature], body: tampered) }
        await engine.refresh()
        XCTAssertEqual(engine.lastError, ShipKitError.invalidSignature.errorDescription)
        XCTAssertEqual(engine.currentVersionStatus, .ok, "tampered snapshot must not apply")

        MockURLProtocol.setHandler { _ in MockResponse(status: 200, body: tampered) }
        await engine.refresh()
        XCTAssertEqual(engine.currentVersionStatus, .ok, "unsigned snapshot must not apply")

        let reloaded = TestEnv.makeEngine(directory: directory) { $0.signingKey = publicKey }
        XCTAssertEqual(reloaded.currentVersionStatus, .ok, "rejected snapshot must not reach the disk cache")
    }

    // MARK: - Feedback queue

    func testFeedbackQueuedOfflineAndFlushedOnRefresh() async throws {
        MockURLProtocol.setHandler(nil)
        let directory = TestEnv.directory()
        let engine = TestEnv.makeEngine(directory: directory)
        let image = ImagePayload(data: Data([0xFF, 0xD8, 0xFF]), contentType: "image/jpeg")
        let result = try await engine.submitFeedback(category: .bug, rating: 4, message: "Export fails", email: nil, images: [image])
        XCTAssertEqual(result, .queued)
        XCTAssertEqual(engine.pendingFeedbackCount, 1)

        let threadJSON = Data(#"{"thread":{"id":"fb_1","category":"bug","rating":4,"status":"new","preview":"Export fails","createdAt":"2026-11-15T10:00:00.123Z","updatedAt":"2026-11-15T10:00:00Z","unread":0,"fixedIn":null}}"#.utf8)
        MockURLProtocol.setHandler { request in
            switch request.url.path {
            case "/v1/snapshot": return MockResponse(status: 200, body: TestEnv.snapshotJSON(status: "ok"))
            case "/v1/uploads": return MockResponse(status: 200, body: Data(#"{"id":"att_1"}"#.utf8))
            case "/v1/feedback": return MockResponse(status: 200, body: threadJSON)
            default: return MockResponse(status: 404)
            }
        }
        await engine.refresh()
        XCTAssertEqual(engine.pendingFeedbackCount, 0)

        let upload = try XCTUnwrap(MockURLProtocol.requests.first { $0.url.path == "/v1/uploads" })
        XCTAssertEqual(upload.headers["Content-Type"], "image/jpeg")
        let feedback = try XCTUnwrap(MockURLProtocol.requests.first { $0.url.path == "/v1/feedback" })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: feedback.body ?? Data()) as? [String: Any])
        XCTAssertEqual(json["category"] as? String, "bug")
        XCTAssertEqual(json["rating"] as? Int, 4)
        XCTAssertEqual(json["attachments"] as? [String], ["att_1"])
        XCTAssertTrue(json["email"] is NSNull)
        XCTAssertEqual((json["context"] as? [String: Any])?["platform"] as? String, "ios")
    }

    func testTelemetryPingOncePerDay() async throws {
        MockURLProtocol.setHandler { request in
            request.url.path == "/v1/events" ? MockResponse(status: 204) : MockResponse(status: 200, body: TestEnv.snapshotJSON(status: "ok"))
        }
        let engine = TestEnv.makeEngine(directory: TestEnv.directory()) { $0.telemetry = .on }
        await engine.refresh()
        _ = engine.variant("new_onboarding", default: "control")
        _ = engine.variant("new_onboarding", default: "control")
        await engine.sendEvents()
        let events = MockURLProtocol.requests.filter { $0.url.path == "/v1/events" }
        XCTAssertEqual(events.count, 2)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: events[0].body ?? Data()) as? [String: Any])
        XCTAssertNotNil(first["ping"])
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: events[1].body ?? Data()) as? [String: Any])
        XCTAssertNil(second["ping"], "ping is sent at most once per day")
        let exposures = try XCTUnwrap(second["exposures"] as? [[String: Any]])
        XCTAssertEqual(exposures.first?["flag"] as? String, "new_onboarding")
        XCTAssertEqual(exposures.first?["variant"] as? String, "on")
        XCTAssertEqual(exposures.first?["count"] as? Int, 1)
    }
}
