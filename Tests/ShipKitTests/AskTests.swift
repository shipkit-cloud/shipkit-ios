import XCTest
@testable import ShipKit

final class AskDecodingTests: XCTestCase {
    private func snapshot(ask: String) throws -> ShipKitSnapshot {
        try ShipKitSnapshot(jsonData: Data("""
        {"release":3,"settings":{"a":1},"flags":{},"version":{"status":"ok"},"ask":\(ask)}
        """.utf8))
    }

    func testQuestionAsk() throws {
        let s = try snapshot(ask: """
        {"id":"cmp_1","kind":"question","title":null,"body":"One question about the editor.",
         "question":{"prompt":"How is the editor?","type":"scale","choices":[]},"feedbackPrompt":null,"endsAt":"2026-12-11T00:00:00Z"}
        """)
        let ask = try XCTUnwrap(s.ask)
        XCTAssertEqual(ask.id, "cmp_1")
        XCTAssertEqual(ask.kind, .question)
        XCTAssertEqual(ask.prompt, "How is the editor?")
        XCTAssertNil(ask.title, "null means the SDK's own invite title")
        XCTAssertEqual(ask.body, "One question about the editor.")
        XCTAssertEqual(ask.question?.type, .scale)
        XCTAssertEqual(ask.endsAt, ISO8601.date(from: "2026-12-11T00:00:00Z"))
        XCTAssertFalse(ask.isTest)
        XCTAssertEqual(s.settings["a"], .int(1), "the rest of the snapshot is unaffected")
    }

    func testFeedbackAndTestAsk() throws {
        let ask = try XCTUnwrap(try snapshot(ask: """
        {"id":"cmp_2","kind":"feedback","title":"Got a minute?","body":"","question":null,"feedbackPrompt":"What should sync do better?","endsAt":null,"test":true}
        """).ask)
        XCTAssertEqual(ask.kind, .feedback)
        XCTAssertEqual(ask.prompt, "What should sync do better?")
        XCTAssertNil(ask.body, "empty text counts as none")
        XCTAssertTrue(ask.isTest)
    }

    func testUnknownOrBrokenAsksAreDropped() throws {
        XCTAssertNil(try snapshot(ask: #"{"id":"cmp_3","kind":"poll","question":null}"#).ask, "a kind from a newer backend")
        XCTAssertNil(try snapshot(ask: #"{"id":"cmp_4","kind":"question","question":{"prompt":"Pick","type":"choice","choices":["Only"]}}"#).ask)
        XCTAssertNil(try snapshot(ask: #"{"id":"cmp_5","kind":"question","question":null}"#).ask)
        XCTAssertEqual(try snapshot(ask: "null").release, 3)
    }

    func testNoAskKey() throws {
        XCTAssertNil(try ShipKitSnapshot(jsonData: TestEnv.snapshotJSON(status: "ok")).ask)
    }

    func testRoundTrip() throws {
        let ask = ShipKitAsk(id: "cmp_6", question: "Best part?", type: .choice, choices: ["Speed", "Design"], title: "Quick one")
        let decoded = try JSON.decoder.decode(ShipKitAsk.self, from: JSON.encoder.encode(ask))
        XCTAssertEqual(decoded, ask)
    }

    func testFeedbackSubmissionCarriesTheAsk() throws {
        var submission = FeedbackSubmission(category: .idea, rating: nil, message: "Sync is slow", email: nil, attachments: [], context: TestEnv.makeEngine(directory: TestEnv.directory()).makeContext())
        var body = try JSONSerialization.jsonObject(with: JSON.encoder.encode(submission)) as? [String: Any]
        XCTAssertNil(body?["askId"])
        XCTAssertNil(body?["askTest"])
        submission.askId = "cmp_7"
        submission.askTest = true
        body = try JSONSerialization.jsonObject(with: JSON.encoder.encode(submission)) as? [String: Any]
        XCTAssertEqual(body?["askId"] as? String, "cmp_7")
        XCTAssertEqual(body?["askTest"] as? Bool, true)
        // A report queued by an older SDK still decodes.
        let old = try JSONSerialization.data(withJSONObject: ["category": "bug", "message": "x", "attachments": [], "context": ["stableId": "s", "appVersion": "1", "build": "1", "platform": "ios"]])
        XCTAssertNil(try JSON.decoder.decode(FeedbackSubmission.self, from: old).askId)
    }
}

final class AskEngineTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private func snapshotBody(status: String = "ok", ask: String) -> Data {
        Data("""
        {"release":1,"ttl":900,"settings":{},"flags":{},"version":{"status":"\(status)"},"ask":\(ask)}
        """.utf8)
    }

    private func question(id: String = "cmp_1", endsAt: String = "2099-01-01T00:00:00Z", test: Bool = false) -> String {
        """
        {"id":"\(id)","kind":"question","title":null,"body":null,"question":{"prompt":"How is it?","type":"yesno","choices":[]},"feedbackPrompt":null,"endsAt":"\(endsAt)"\(test ? #","test":true"# : "")}
        """
    }

    /// An engine whose cached snapshot carries `ask`, then taken offline.
    private func engine(ask: String, status: String = "ok", preferences: Preferences = TestEnv.preferences(), directory: URL = TestEnv.directory()) async -> Engine {
        let body = snapshotBody(status: status, ask: ask)
        MockURLProtocol.setHandler { request in
            request.url.path == "/v1/snapshot" ? MockResponse(status: 200, headers: ["ETag": "\"e\""], body: body) : MockResponse(status: 204)
        }
        let engine = TestEnv.makeEngine(directory: directory, preferences: preferences)
        await engine.refresh()
        MockURLProtocol.setHandler(nil)
        return engine
    }

    /// Lets the flush that recording an event starts in the background finish.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    private func json(_ request: RecordedRequest?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request?.body)) as? [String: Any])
    }

    func testPendingUntilShownAndRememberedAcrossLaunches() async throws {
        let preferences = TestEnv.preferences()
        let directory = TestEnv.directory()
        let engine = await engine(ask: question(), preferences: preferences, directory: directory)
        let ask = try XCTUnwrap(engine.pendingAsk())
        XCTAssertEqual(ask.id, "cmp_1")

        engine.markAskShown(ask)
        XCTAssertNil(engine.pendingAsk(), "never twice")
        await settle()

        let relaunched = TestEnv.makeEngine(directory: directory, preferences: preferences)
        XCTAssertEqual(relaunched.snapshot?.ask?.id, "cmp_1", "still in the cached snapshot")
        XCTAssertNil(relaunched.pendingAsk(), "but remembered as seen")
    }

    func testOptOutExpiryAndBlockingHoldItBack() async throws {
        let preferences = TestEnv.preferences()
        preferences.set(false, for: .pushAsks)
        let optedOut = await engine(ask: question(), preferences: preferences)
        XCTAssertNil(optedOut.pendingAsk())

        let test = await engine(ask: question(test: true), preferences: preferences)
        XCTAssertEqual(test.pendingAsk()?.id, "cmp_1", "a dashboard test shows even when opted out")

        let expired = await engine(ask: question(endsAt: "2020-01-01T00:00:00Z"))
        XCTAssertNil(expired.pendingAsk())

        let blocked = await engine(ask: question(), status: "blocked")
        XCTAssertNil(blocked.pendingAsk(), "the block screen comes first")
    }

    func testTestAsksAreNotRememberedAsSeen() async throws {
        let preferences = TestEnv.preferences()
        let directory = TestEnv.directory()
        let engine = await engine(ask: question(test: true), preferences: preferences, directory: directory)
        engine.markAskShown(try XCTUnwrap(engine.pendingAsk()))
        XCTAssertNil(engine.pendingAsk(), "not twice in one launch")
        await settle()
        XCTAssertEqual(TestEnv.makeEngine(directory: directory, preferences: preferences).pendingAsk()?.id, "cmp_1", "the next test shows again")
    }

    func testEventsWaitOfflineAndGoOutInOrder() async throws {
        let engine = await engine(ask: question(test: true))
        let ask = try XCTUnwrap(engine.pendingAsk())
        engine.markAskShown(ask)
        engine.dismissAsk(ask)
        await settle()
        XCTAssertEqual(engine.pendingAskEvents.map(\.kind), [.shown, .dismissed])

        MockURLProtocol.setHandler { _ in MockResponse(status: 204) }
        await engine.flushAskOutbox()
        let sent = MockURLProtocol.requests.filter { $0.url.path.hasPrefix("/v1/asks/") }
        XCTAssertEqual(sent.map(\.url.path), ["/v1/asks/cmp_1/events", "/v1/asks/cmp_1/events"])
        let first = try json(sent.first)
        XCTAssertEqual(first["event"] as? String, "shown")
        XCTAssertEqual(first["test"] as? Bool, true)
        XCTAssertEqual(first["appVersion"] as? String, "2.4.0")
        XCTAssertNotNil(first["at"] as? String)
        XCTAssertEqual(try json(sent.last)["event"] as? String, "dismissed")
        XCTAssertTrue(engine.pendingAskEvents.isEmpty)
    }

    func testRejectedEventsAreDropped() async throws {
        let engine = await engine(ask: question())
        engine.markAskShown(try XCTUnwrap(engine.pendingAsk()))
        await settle()
        MockURLProtocol.setHandler { _ in MockResponse(status: 404, body: Data(#"{"error":{"code":"not_found"}}"#.utf8)) }
        await engine.flushAskOutbox()
        XCTAssertTrue(engine.pendingAskEvents.isEmpty, "a deleted ask is not retried forever")
    }

    func testRefreshSendsWaitingEventsBeforeTheSnapshot() async throws {
        let engine = await engine(ask: question())
        engine.markAskShown(try XCTUnwrap(engine.pendingAsk()))
        await settle()
        let body = snapshotBody(ask: "null")
        MockURLProtocol.setHandler { request in
            request.url.path == "/v1/snapshot" ? MockResponse(status: 200, body: body) : MockResponse(status: 204)
        }
        await engine.refresh()
        let paths = MockURLProtocol.requests.map(\.url.path)
        let event = try XCTUnwrap(paths.firstIndex(of: "/v1/asks/cmp_1/events"))
        let snapshot = try XCTUnwrap(paths.firstIndex(of: "/v1/snapshot"))
        XCTAssertLessThan(event, snapshot, "the server must know the ask was seen before it builds the next snapshot")
        XCTAssertNil(engine.snapshot?.ask)
    }

    func testAnswerOnlineAndOffline() async throws {
        let engine = await engine(ask: question())
        let ask = try XCTUnwrap(engine.pendingAsk())

        MockURLProtocol.setHandler { _ in MockResponse(status: 200, body: Data(#"{"ok":true,"threadId":null}"#.utf8)) }
        try await engine.answerAsk(ask, answer: PushAnswer(value: .string("yes"), text: "Love it"))
        let request = try XCTUnwrap(MockURLProtocol.requests.last)
        XCTAssertEqual(request.url.path, "/v1/asks/cmp_1/answer")
        let body = try json(request)
        XCTAssertEqual(body["value"] as? String, "yes")
        XCTAssertEqual(body["text"] as? String, "Love it")
        XCTAssertEqual(body["test"] as? Bool, false)
        XCTAssertEqual((body["context"] as? [String: Any])?["appVersion"] as? String, "2.4.0")

        MockURLProtocol.setHandler(nil)
        try await engine.answerAsk(ask, answer: PushAnswer(value: .string("no")))
        XCTAssertEqual(engine.pendingAskEvents.map(\.kind), [.answered], "kept for later, not an error for the user")

        MockURLProtocol.setHandler { _ in MockResponse(status: 200, body: Data(#"{"ok":true}"#.utf8)) }
        await engine.flushAskOutbox()
        XCTAssertEqual(try json(MockURLProtocol.requests.last)["value"] as? String, "no")
        XCTAssertTrue(engine.pendingAskEvents.isEmpty)
    }

    func testFeedbackAskIsSentWithTheFeedback() async throws {
        let engine = await engine(ask: question())
        let ask = ShipKitAsk(id: "cmp_9", feedbackPrompt: "What should we fix?")
        MockURLProtocol.setHandler { _ in
            MockResponse(status: 200, body: Data(#"{"thread":{"id":"fb_1","category":"idea","rating":null,"status":"new","preview":"x","createdAt":"2026-11-27T10:00:00Z","updatedAt":"2026-11-27T10:00:00Z","unread":0,"fixedIn":null}}"#.utf8))
        }
        _ = try await engine.submitFeedback(category: .idea, rating: nil, message: "Search", email: nil, images: [], ask: ask)
        let request = try XCTUnwrap(MockURLProtocol.requests.last { $0.url.path == "/v1/feedback" })
        XCTAssertEqual(try json(request)["askId"] as? String, "cmp_9")
    }
}
