import CryptoKit
import os
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

    func testNotModifiedMustBeSignedWhenSigningEnabled() async throws {
        let signer = TestSigner()
        let body = TestEnv.snapshotJSON(status: "ok")
        MockURLProtocol.setHandler { signer.ok($0, body: body, etag: "\"s1\"") }
        let engine = TestEnv.makeEngine(directory: TestEnv.directory()) { $0.signingKey = signer.publicKey }
        await engine.refresh()
        XCTAssertEqual(engine.snapshot?.release, 1)
        let firstCheck = try XCTUnwrap(engine.meta?.fetchedAt)

        // A bare 304 would let a proxy freeze the cache, so it doesn't count as a check.
        MockURLProtocol.setHandler { _ in MockResponse(status: 304) }
        await engine.refresh()
        XCTAssertEqual(engine.lastError, ShipKitError.invalidSignature.errorDescription)
        XCTAssertEqual(engine.meta?.fetchedAt, firstCheck)

        // Signed for some other body: rejected too.
        MockURLProtocol.setHandler { signer.notModified($0, cachedBody: TestEnv.snapshotJSON(status: "blocked")) }
        await engine.refresh()
        XCTAssertEqual(engine.lastError, ShipKitError.invalidSignature.errorDescription)

        MockURLProtocol.setHandler { signer.notModified($0, cachedBody: body) }
        await engine.refresh()
        XCTAssertNil(engine.lastError)
        XCTAssertEqual(engine.snapshot?.release, 1)
        XCTAssertGreaterThan(try XCTUnwrap(engine.meta?.fetchedAt), firstCheck)
    }

    func testRejectsTamperedOrUnsignedSnapshotWhenSigningEnabled() async throws {
        let signer = TestSigner()
        let good = TestEnv.snapshotJSON(status: "ok")

        let directory = TestEnv.directory()
        let preferences = TestEnv.preferences()
        MockURLProtocol.setHandler { signer.ok($0, body: good) }
        let engine = TestEnv.makeEngine(directory: directory, preferences: preferences) { $0.signingKey = signer.publicKey }
        await engine.refresh()
        XCTAssertEqual(engine.settingValue("max_upload_mb"), .int(50))

        let tampered = TestEnv.snapshotJSON(status: "blocked")
        MockURLProtocol.setHandler { request in
            MockResponse(status: 200, headers: ["X-ShipKit-Signature-V2": signer.signature(for: request, body: good)], body: tampered)
        }
        await engine.refresh()
        XCTAssertEqual(engine.lastError, ShipKitError.invalidSignature.errorDescription)
        XCTAssertEqual(engine.currentVersionStatus, .ok, "tampered snapshot must not apply")

        MockURLProtocol.setHandler { _ in MockResponse(status: 200, body: tampered) }
        await engine.refresh()
        XCTAssertEqual(engine.currentVersionStatus, .ok, "unsigned snapshot must not apply")

        // The body-only signature of SDK 1.1 says nothing about the request, so it isn't enough.
        let legacy = try signer.key.signature(for: tampered).base64EncodedString()
        MockURLProtocol.setHandler { _ in MockResponse(status: 200, headers: ["X-ShipKit-Signature": legacy], body: tampered) }
        await engine.refresh()
        XCTAssertEqual(engine.currentVersionStatus, .ok, "a body-only signature must not apply")

        let reloaded = TestEnv.makeEngine(directory: directory, preferences: preferences) { $0.signingKey = signer.publicKey }
        XCTAssertEqual(reloaded.currentVersionStatus, .ok, "rejected snapshot must not reach the disk cache")
        XCTAssertEqual(reloaded.settingValue("max_upload_mb"), .int(50), "the verified cache is still served")
    }

    /// The reported bypass: a proxy rewrites the request to claim a newer version, and the server
    /// answers with a correctly signed "ok" for that version.
    func testSignedAnswerToAnEditedRequestIsRejected() async throws {
        let signer = TestSigner()
        let okFor99 = TestEnv.snapshotJSON(status: "ok", extra: #","current":"99.0.0""#)
        MockURLProtocol.setHandler { request in
            var edited = request
            var json = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any] ?? [:]
            json["appVersion"] = "99.0.0"
            edited.body = try? JSONSerialization.data(withJSONObject: json)
            return signer.ok(edited, body: okFor99)
        }
        let engine = TestEnv.makeEngine(directory: TestEnv.directory(), appVersion: "1.0.0") { $0.signingKey = signer.publicKey }
        await engine.refresh()
        XCTAssertEqual(engine.lastError, ShipKitError.invalidSignature.errorDescription)
        XCTAssertNil(engine.snapshot, "an answer to a request the app never sent must not apply")

        // The honest answer for the version that is really running does apply.
        let required = TestEnv.snapshotJSON(status: "required", extra: #","current":"1.0.0""#)
        MockURLProtocol.setHandler { signer.ok($0, body: required) }
        await engine.refresh()
        guard case .updateRequired = engine.currentVersionStatus else { return XCTFail("expected required") }
    }

    func testAnswerForAnotherVersionIsRejectedWithoutSigning() async {
        MockURLProtocol.setHandler { _ in
            MockResponse(status: 200, body: TestEnv.snapshotJSON(status: "ok", extra: #","current":"99.0.0""#))
        }
        let engine = TestEnv.makeEngine(directory: TestEnv.directory(), appVersion: "1.0.0")
        await engine.refresh()
        XCTAssertEqual(engine.lastError, ShipKitError.invalidResponse.errorDescription)
        XCTAssertNil(engine.snapshot)
    }

    func testReplayedSignedResponseIsRejected() async throws {
        let signer = TestSigner()
        let old = TestEnv.snapshotJSON(status: "ok")
        let captured = OSAllocatedUnfairLock<MockResponse?>(initialState: nil)
        MockURLProtocol.setHandler { request in
            let response = signer.ok(request, body: old)
            captured.withLock { $0 = response }
            return response
        }
        let directory = TestEnv.directory()
        let preferences = TestEnv.preferences()
        let engine = TestEnv.makeEngine(directory: directory, preferences: preferences) { $0.signingKey = signer.publicKey }
        await engine.refresh()
        XCTAssertNil(engine.lastError)
        let firstCheck = try XCTUnwrap(engine.meta?.fetchedAt)

        // Every request carries a fresh nonce, so yesterday's response never fits today's request.
        let replay = try XCTUnwrap(captured.withLock { $0 })
        MockURLProtocol.setHandler { _ in replay }
        await engine.refresh()
        XCTAssertEqual(engine.lastError, ShipKitError.invalidSignature.errorDescription)
        XCTAssertEqual(engine.meta?.fetchedAt, firstCheck, "a replay must not count as a fresh check")

        let bodies = MockURLProtocol.requests.compactMap(\.body)
        let nonces = bodies.compactMap { ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any])?["nonce"] as? String }
        XCTAssertEqual(nonces.count, 1, "handler was replaced, so only the second request is recorded")
        XCTAssertFalse(nonces[0].isEmpty)
    }

    func testEditedDiskCacheIsDiscardedWhenSigningEnabled() async throws {
        let signer = TestSigner()
        let directory = TestEnv.directory()
        let preferences = TestEnv.preferences()
        MockURLProtocol.setHandler { signer.ok($0, body: TestEnv.snapshotJSON(status: "required")) }
        await TestEnv.makeEngine(directory: directory, preferences: preferences) { $0.signingKey = signer.publicKey }.refresh()

        MockURLProtocol.setHandler(nil)
        let intact = TestEnv.makeEngine(directory: directory, preferences: preferences) { $0.signingKey = signer.publicKey }
        guard case .updateRequired = intact.currentVersionStatus else { return XCTFail("verified cache must load") }

        try TestEnv.snapshotJSON(status: "ok").write(to: directory.appendingPathComponent("snapshot.json"))
        let edited = TestEnv.makeEngine(directory: directory, preferences: preferences) { $0.signingKey = signer.publicKey }
        XCTAssertNil(edited.snapshot, "a cache that no longer matches its signature is dropped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("snapshot.json").path))
    }

    func testCacheFromAnotherInstallIsDiscardedWhenSigningEnabled() async {
        let signer = TestSigner()
        let directory = TestEnv.directory()
        MockURLProtocol.setHandler { signer.ok($0, body: TestEnv.snapshotJSON(status: "ok")) }
        await TestEnv.makeEngine(directory: directory) { $0.signingKey = signer.publicKey }.refresh()

        MockURLProtocol.setHandler(nil)
        // Fresh preferences mean a different install ID reading the same files.
        let other = TestEnv.makeEngine(directory: directory) { $0.signingKey = signer.publicKey }
        XCTAssertNil(other.snapshot)
    }

    func testUnparseableSigningKeyRejectsEverything() async {
        MockURLProtocol.setHandler { _ in MockResponse(status: 200, body: TestEnv.snapshotJSON(status: "ok")) }
        let engine = TestEnv.makeEngine(directory: TestEnv.directory()) { $0.signingKey = "not a key" }
        await engine.refresh()
        XCTAssertEqual(engine.lastError, ShipKitError.invalidSignature.errorDescription)
        XCTAssertNil(engine.snapshot)
    }

    // MARK: - Version check max age

    func testNoMaxAgeNeverHoldsTheApp() async {
        MockURLProtocol.setHandler(nil)
        let engine = TestEnv.makeEngine(directory: TestEnv.directory())
        let status = await engine.versionStatus()
        XCTAssertEqual(status, .ok)
        XCTAssertFalse(engine.isVersionCheckOverdue(lastChecked: .distantPast))
    }

    func testOverdueCheckHoldsTheAppUntilOneSucceeds() async throws {
        let directory = TestEnv.directory()
        let preferences = TestEnv.preferences()
        MockURLProtocol.setHandler { _ in MockResponse(status: 200, headers: ["ETag": "\"a\""], body: TestEnv.snapshotJSON(status: "ok")) }
        await TestEnv.makeEngine(directory: directory, preferences: preferences).refresh()

        try await Task.sleep(for: .milliseconds(300))
        MockURLProtocol.setHandler(nil)
        let engine = TestEnv.makeEngine(directory: directory, preferences: preferences) { $0.versionCheckMaxAge = 0.2 }
        XCTAssertEqual(engine.currentVersionStatus, .ok, "not before this session's own check has had its chance")
        let offline = await engine.versionStatus()
        XCTAssertEqual(offline, .checkRequired)
        XCTAssertTrue(offline.isBlocking)
        XCTAssertEqual(engine.settingValue("max_upload_mb"), .int(50), "cached values stay readable")

        MockURLProtocol.setHandler { _ in MockResponse(status: 304) }
        await engine.refresh()
        XCTAssertEqual(engine.currentVersionStatus, .ok, "a successful check, even an unchanged one, lifts it")
    }

    func testMaxAgeCountsFromFirstLaunchWhenNothingWasEverFetched() async throws {
        MockURLProtocol.setHandler(nil)
        let directory = TestEnv.directory()
        let preferences = TestEnv.preferences()
        let first = TestEnv.makeEngine(directory: directory, preferences: preferences) { $0.versionCheckMaxAge = 3600 }
        let fresh = await first.versionStatus()
        XCTAssertEqual(fresh, .ok, "a new install gets the full window")

        XCTAssertTrue(first.isVersionCheckOverdue(lastChecked: nil, now: Date().addingTimeInterval(3601)))
        XCTAssertFalse(first.isVersionCheckOverdue(lastChecked: nil, now: Date().addingTimeInterval(3500)))
        XCTAssertTrue(first.isVersionCheckOverdue(lastChecked: Date().addingTimeInterval(7 * 86_400)), "a clock moved back doesn't buy time")

        let second = TestEnv.makeEngine(directory: directory, preferences: preferences) { $0.versionCheckMaxAge = 3600 }
        XCTAssertEqual(second.firstLaunch.timeIntervalSince1970, first.firstLaunch.timeIntervalSince1970, accuracy: 0.001)
    }

    func testOverdueCheckNeverHidesABlock() async {
        let directory = TestEnv.directory()
        let preferences = TestEnv.preferences()
        MockURLProtocol.setHandler { _ in MockResponse(status: 200, body: TestEnv.snapshotJSON(status: "required")) }
        await TestEnv.makeEngine(directory: directory, preferences: preferences).refresh()
        try? await Task.sleep(for: .milliseconds(150))
        MockURLProtocol.setHandler(nil)
        let engine = TestEnv.makeEngine(directory: directory, preferences: preferences) { $0.versionCheckMaxAge = 0.1 }
        let status = await engine.versionStatus()
        guard case .updateRequired = status else { return XCTFail("the update screen wins over the connect screen") }
    }

    // MARK: - Debug tools

    func testDebugToolsDisabledIgnoresSimulationAndOverrides() async throws {
        let directory = TestEnv.directory()
        let preferences = TestEnv.preferences()
        preferences.defaults.set("9.9.9", forKey: ShipKitDefaults.simulatedVersionKey)
        preferences.defaults.set("9.9.9", forKey: ShipKitDefaults.simulateVersionArgumentKey)
        preferences.encode(Overrides(settings: ["max_upload_mb": 999], flags: ["new_onboarding": false]), .overrides)

        MockURLProtocol.setHandler { _ in MockResponse(status: 200, body: TestEnv.snapshotJSON(status: "required")) }
        let engine = TestEnv.makeEngine(directory: directory, preferences: preferences, appVersion: "1.0.0") { $0.debugTools = .disabled }
        await engine.refresh()

        let body = try XCTUnwrap(MockURLProtocol.requests.first?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["appVersion"] as? String, "1.0.0", "the real version is sent")
        XCTAssertEqual(engine.runningVersionString, "1.0.0")
        guard case .updateRequired = engine.currentVersionStatus else { return XCTFail("expected required") }

        XCTAssertEqual(engine.settingValue("max_upload_mb"), .int(50), "stored overrides are not applied")
        XCTAssertTrue(engine.isEnabled("new_onboarding"))
        engine.setOverride(setting: "max_upload_mb", value: 1)
        XCTAssertEqual(engine.settingValue("max_upload_mb"), .int(50), "new overrides are refused")
        engine.setSimulatedVersion("8.8.8")
        XCTAssertEqual(preferences.defaults.string(forKey: ShipKitDefaults.simulatedVersionKey), "9.9.9", "simulation can't be set")
    }

    func testDebugToolsModes() {
        XCTAssertTrue(ShipKitDebugTools.enabled.isEnabled)
        XCTAssertFalse(ShipKitDebugTools.disabled.isEnabled)
        // Tests are a debug build.
        XCTAssertTrue(ShipKitDebugTools.automatic.isEnabled)
        XCTAssertEqual(ShipKitOptions().debugTools, .automatic)
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
