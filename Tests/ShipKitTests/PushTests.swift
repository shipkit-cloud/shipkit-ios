import UserNotifications
import XCTest
@testable import ShipKit

final class PushPayloadTests: XCTestCase {
    private func userInfo(_ shipkit: [String: Any], alert: [String: Any]? = ["title": "Quick question", "body": "How is it going?"]) -> [AnyHashable: Any] {
        var aps: [String: Any] = ["sound": "default", "thread-id": "shipkit"]
        if let alert { aps["alert"] = alert }
        return ["aps": aps, "shipkit": shipkit]
    }

    func testStatusUpdatePayload() throws {
        let payload = try XCTUnwrap(PushPayload(userInfo: userInfo(
            ["kind": "update", "u": "upn_1", "target": "request", "ref": "req_9"],
            alert: ["title": "Feature request", "body": "“Dark mode” shipped in version 2.2.0."]
        )))
        XCTAssertEqual(payload.kind, .update)
        XCTAssertEqual(payload.updateID, "upn_1")
        XCTAssertEqual(payload.target, "request")
        XCTAssertEqual(payload.ref, "req_9")
        XCTAssertNil(payload.deliveryID, "no campaign delivery to record or fetch")
        XCTAssertFalse(payload.needsFetch)

        let noRef = try XCTUnwrap(PushPayload(userInfo: userInfo(["kind": "update", "u": "upn_2", "target": "thread", "ref": NSNull()])))
        XCTAssertNil(noRef.ref)
    }

    func testNonShipKitNotificationIsIgnored() {
        XCTAssertNil(PushPayload(userInfo: ["aps": ["alert": "Hi"]]))
        XCTAssertNil(PushPayload(userInfo: ["shipkit": "not an object"]))
        XCTAssertFalse(ShipKit.isShipKitNotification(["aps": [:]]))
        XCTAssertTrue(ShipKit.isShipKitNotification(["shipkit": ["d": "dlv_1"]]))
    }

    func testScaleQuestion() throws {
        let payload = try XCTUnwrap(PushPayload(userInfo: userInfo([
            "d": "dlv_1", "c": "cmp_1", "kind": "question",
            "question": ["prompt": "How is the new editor working for you?", "type": "scale", "choices": []],
            "feedbackPrompt": NSNull(), "url": NSNull()
        ])))
        XCTAssertEqual(payload.deliveryID, "dlv_1")
        XCTAssertEqual(payload.campaignID, "cmp_1")
        XCTAssertEqual(payload.kind, .question)
        XCTAssertEqual(payload.question?.type, .scale)
        XCTAssertEqual(payload.question?.prompt, "How is the new editor working for you?")
        XCTAssertEqual(payload.title, "Quick question")
        XCTAssertEqual(payload.body, "How is it going?")
        XCTAssertNil(payload.url)
        XCTAssertNil(payload.feedbackPrompt)
        XCTAssertFalse(payload.needsFetch)
    }

    func testAllQuestionTypes() throws {
        for type in PushQuestion.Kind.allCases {
            let choices: [String] = type == .choice ? ["Speed", "Design", "Price"] : []
            let payload = try XCTUnwrap(PushPayload(userInfo: userInfo([
                "d": "dlv_\(type.rawValue)", "kind": "question",
                "question": ["prompt": "Prompt", "type": type.rawValue, "choices": choices]
            ])))
            XCTAssertEqual(payload.question?.type, type)
            XCTAssertEqual(payload.question?.choices, choices)
            XCTAssertTrue(payload.question?.isComplete ?? false, "\(type) should be complete")
            XCTAssertFalse(payload.needsFetch)
        }
    }

    func testMessageAndFeedbackKinds() throws {
        let message = try XCTUnwrap(PushPayload(userInfo: userInfo([
            "d": "dlv_m", "kind": "message", "question": NSNull(), "feedbackPrompt": NSNull(), "url": "myapp://promo"
        ])))
        XCTAssertEqual(message.kind, .message)
        XCTAssertEqual(message.url, "myapp://promo")
        XCTAssertNil(message.question)
        XCTAssertFalse(message.needsFetch)

        let plainMessage = try XCTUnwrap(PushPayload(userInfo: userInfo(["d": "dlv_m2", "kind": "message", "url": NSNull()])))
        XCTAssertNil(plainMessage.url)
        XCTAssertFalse(plainMessage.needsFetch, "an explicit null url means just open the app")

        let feedback = try XCTUnwrap(PushPayload(userInfo: userInfo([
            "d": "dlv_f", "kind": "feedback", "feedbackPrompt": "What should we build next?", "url": NSNull()
        ])))
        XCTAssertEqual(feedback.kind, .feedback)
        XCTAssertEqual(feedback.feedbackPrompt, "What should we build next?")
        XCTAssertFalse(feedback.needsFetch)

        let blankPrompt = try XCTUnwrap(PushPayload(userInfo: userInfo(["d": "dlv_f2", "kind": "feedback", "feedbackPrompt": "  "])))
        XCTAssertNil(blankPrompt.feedbackPrompt)
    }

    func testMissingFieldsNeedFetch() throws {
        let noKind = try XCTUnwrap(PushPayload(userInfo: userInfo(["d": "dlv_1"])))
        XCTAssertNil(noKind.kind)
        XCTAssertTrue(noKind.needsFetch)

        let noQuestion = try XCTUnwrap(PushPayload(userInfo: userInfo(["d": "dlv_2", "kind": "question"])))
        XCTAssertTrue(noQuestion.needsFetch)

        let noPrompt = try XCTUnwrap(PushPayload(userInfo: userInfo(["d": "dlv_3", "kind": "question", "question": ["type": "yesno"]])))
        XCTAssertTrue(noPrompt.needsFetch)
        XCTAssertEqual(noPrompt.displayPrompt, "How is it going?", "falls back to the alert body")

        let tooFewChoices = try XCTUnwrap(PushPayload(userInfo: userInfo([
            "d": "dlv_4", "kind": "question", "question": ["prompt": "Pick", "type": "choice", "choices": ["Only"]]
        ])))
        XCTAssertTrue(tooFewChoices.needsFetch)

        let unknownType = try XCTUnwrap(PushPayload(userInfo: userInfo([
            "d": "dlv_5", "kind": "question", "question": ["prompt": "?", "type": "slider"]
        ])))
        XCTAssertNil(unknownType.question?.type)
        XCTAssertTrue(unknownType.needsFetch)

        let trimmedMessage = try XCTUnwrap(PushPayload(userInfo: userInfo(["d": "dlv_6", "kind": "message"])))
        XCTAssertTrue(trimmedMessage.needsFetch, "url key missing entirely")

        let trimmedFeedback = try XCTUnwrap(PushPayload(userInfo: userInfo(["d": "dlv_7", "kind": "feedback"])))
        XCTAssertTrue(trimmedFeedback.needsFetch, "feedbackPrompt key missing entirely")

        let unknownKind = try XCTUnwrap(PushPayload(userInfo: userInfo(["d": "dlv_8", "kind": "survey"])))
        XCTAssertNil(unknownKind.kind)
        XCTAssertTrue(unknownKind.needsFetch)

        let noDelivery = try XCTUnwrap(PushPayload(userInfo: userInfo(["kind": "question"])))
        XCTAssertNil(noDelivery.deliveryID)
        XCTAssertFalse(noDelivery.needsFetch, "nothing to fetch without a delivery id")
    }

    func testStringAlert() throws {
        let payload = try XCTUnwrap(PushPayload(userInfo: ["aps": ["alert": "Plain body"], "shipkit": ["d": "dlv_1", "kind": "message"]]))
        XCTAssertEqual(payload.body, "Plain body")
        XCTAssertNil(payload.title)
    }

    func testDeliveryResponse() throws {
        let data = Data("""
        { "delivery": { "id": "dlv_9", "kind": "question", "title": "T", "body": "B",
          "question": { "prompt": "Why?", "type": "choice", "choices": ["Speed", "Design", "Price"] },
          "feedbackPrompt": null, "url": null, "answered": true } }
        """.utf8)
        let payload = try PushPayload(deliveryResponse: data)
        XCTAssertEqual(payload.deliveryID, "dlv_9")
        XCTAssertEqual(payload.kind, .question)
        XCTAssertEqual(payload.title, "T")
        XCTAssertEqual(payload.question?.choices, ["Speed", "Design", "Price"])
        XCTAssertTrue(payload.answered)
        XCTAssertFalse(payload.needsFetch)

        XCTAssertThrowsError(try PushPayload(deliveryResponse: Data("{\"error\":{}}".utf8)))
    }

    func testMergeKeepsAlertTextAndFillsQuestion() throws {
        let partial = try XCTUnwrap(PushPayload(userInfo: userInfo(["d": "dlv_1", "kind": "question"])))
        let fetched = try PushPayload(deliveryResponse: Data("""
        {"delivery":{"id":"dlv_1","kind":"question","title":"Server title","body":"Server body",
         "question":{"prompt":"Full prompt","type":"choice","choices":["A","B"]},"feedbackPrompt":null,"url":null,"answered":false}}
        """.utf8))
        let merged = partial.merged(with: fetched)
        XCTAssertEqual(merged.title, "Quick question")
        XCTAssertEqual(merged.question?.prompt, "Full prompt")
        XCTAssertEqual(merged.question?.choices, ["A", "B"])
        XCTAssertFalse(merged.needsFetch)
    }
}

final class PushLogicTests: XCTestCase {
    func testTokenHexEncoding() {
        XCTAssertEqual(PushTokenEncoding.hex(Data([0x00, 0x0f, 0xa1, 0xff, 0x10])), "000fa1ff10")
        XCTAssertEqual(PushTokenEncoding.hex(Data()), "")
        let token = Data((0..<32).map { UInt8($0 * 8 % 256) })
        let hex = PushTokenEncoding.hex(token)
        XCTAssertEqual(hex.count, 64)
        XCTAssertEqual(hex, token.map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(hex, hex.lowercased())
    }

    func testActionToAnswerMapping() {
        XCTAssertEqual(PushAnswer.fromAction("SHIPKIT_YES", userText: nil), PushAnswer(value: .string("yes")))
        XCTAssertEqual(PushAnswer.fromAction("SHIPKIT_NO", userText: nil), PushAnswer(value: .string("no")))
        for score in 1...5 {
            XCTAssertEqual(PushAnswer.fromAction("SHIPKIT_S\(score)", userText: nil), PushAnswer(value: .int(score)))
        }
        XCTAssertNil(PushAnswer.fromAction("SHIPKIT_S0", userText: nil))
        XCTAssertNil(PushAnswer.fromAction("SHIPKIT_S6", userText: nil))
        XCTAssertNil(PushAnswer.fromAction("SHIPKIT_SX", userText: nil))
        XCTAssertEqual(PushAnswer.fromAction("SHIPKIT_REPLY", userText: "  Love it  "), PushAnswer(value: nil, text: "Love it"))
        XCTAssertNil(PushAnswer.fromAction("SHIPKIT_REPLY", userText: "   "))
        XCTAssertNil(PushAnswer.fromAction("SHIPKIT_REPLY", userText: nil))
        XCTAssertNil(PushAnswer.fromAction(UNNotificationDefaultActionIdentifier, userText: nil))
        XCTAssertNil(PushAnswer.fromAction("APP_ACTION", userText: nil))
    }

    func testAuthorizationStrings() {
        XCTAssertEqual(PushAuthorization.string(.authorized), "authorized")
        XCTAssertEqual(PushAuthorization.string(.provisional), "provisional")
        #if os(iOS)
        XCTAssertEqual(PushAuthorization.string(.ephemeral), "ephemeral")
        #endif
        XCTAssertEqual(PushAuthorization.string(.denied), "denied")
        XCTAssertEqual(PushAuthorization.string(.notDetermined), "notDetermined")
    }

    func testEnvironmentResolution() {
        var options = ShipKitPushOptions()
        #if DEBUG
        XCTAssertEqual(options.resolvedEnvironment, .sandbox)
        #else
        XCTAssertEqual(options.resolvedEnvironment, .production)
        #endif
        options.environment = .production
        XCTAssertEqual(options.resolvedEnvironment, .production)
    }

    private func titles() -> PushCategories.Titles {
        .init(yes: "Yes", no: "No", reply: "Reply", replySend: "Send", replyPlaceholder: "Type")
    }

    func testCategoriesMatchContract() throws {
        let categories = PushCategories.make(titles: titles())
        let byID = Dictionary(uniqueKeysWithValues: categories.map { ($0.identifier, $0) })
        XCTAssertEqual(Set(byID.keys), ["SHIPKIT_YESNO", "SHIPKIT_SCALE", "SHIPKIT_TEXT", "SHIPKIT_OPEN"])
        XCTAssertEqual(byID["SHIPKIT_YESNO"]?.actions.map(\.identifier), ["SHIPKIT_YES", "SHIPKIT_NO"])
        XCTAssertEqual(byID["SHIPKIT_SCALE"]?.actions.map(\.identifier), ["SHIPKIT_S1", "SHIPKIT_S2", "SHIPKIT_S3", "SHIPKIT_S4", "SHIPKIT_S5"])
        XCTAssertEqual(byID["SHIPKIT_SCALE"]?.actions.map(\.title).last, "★★★★★")
        XCTAssertEqual(byID["SHIPKIT_SCALE"]?.actions.map(\.title).first, "★☆☆☆☆")
        let reply = try XCTUnwrap(byID["SHIPKIT_TEXT"]?.actions.first as? UNTextInputNotificationAction)
        XCTAssertEqual(reply.identifier, "SHIPKIT_REPLY")
        XCTAssertEqual(byID["SHIPKIT_OPEN"]?.actions.count, 0)
        for category in categories {
            XCTAssertTrue(category.options.contains(.customDismissAction), "\(category.identifier) needs dismiss callbacks")
        }
    }

    func testCategoryMergeKeepsAppCategories() {
        let appCategory = UNNotificationCategory(identifier: "APP_REMINDER", actions: [], intentIdentifiers: [], options: [])
        let staleOurs = UNNotificationCategory(identifier: "SHIPKIT_YESNO", actions: [], intentIdentifiers: [], options: [])
        let ours = PushCategories.make(titles: titles())

        let merged = PushCategories.merge(existing: [appCategory, staleOurs], shipKit: ours)
        XCTAssertEqual(merged.count, 5)
        XCTAssertTrue(merged.contains { $0.identifier == "APP_REMINDER" })
        let yesNo = merged.filter { $0.identifier == "SHIPKIT_YESNO" }
        XCTAssertEqual(yesNo.count, 1, "stale ShipKit category is replaced, not duplicated")
        XCTAssertEqual(yesNo.first?.actions.count, 2)

        XCTAssertEqual(PushCategories.merge(existing: [], shipKit: ours).count, 4)
        XCTAssertTrue(PushCategories.needsRegistration(existing: [appCategory]))
        XCTAssertFalse(PushCategories.needsRegistration(existing: merged))
    }
}

final class PushEngineTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private func json(_ request: RecordedRequest?) throws -> [String: Any] {
        let body = try XCTUnwrap(request?.body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    func testTokenRegistrationBodyAndAsksCache() async throws {
        MockURLProtocol.setHandler { _ in MockResponse(status: 200, body: Data("{\"asks\": false}".utf8)) }
        let preferences = TestEnv.preferences()
        let engine = TestEnv.makeEngine(directory: TestEnv.directory(), preferences: preferences)
        XCTAssertTrue(engine.pushAsksEnabled, "defaults to on")

        engine.storePushToken(PushTokenEncoding.hex(Data([0xab, 0x01])))
        await engine.postPushToken(authorization: "authorized", environment: .sandbox)

        let request = try XCTUnwrap(MockURLProtocol.requests.last)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.path, "/v1/push/token")
        XCTAssertEqual(request.headers["Authorization"], "Bearer skc_test")
        let body = try json(request)
        XCTAssertEqual(body["token"] as? String, "ab01")
        XCTAssertEqual(body["environment"] as? String, "sandbox")
        XCTAssertEqual(body["authorization"] as? String, "authorized")
        XCTAssertEqual(body["capabilities"] as? [String], ["updates"])
        let context = try XCTUnwrap(body["context"] as? [String: Any])
        XCTAssertEqual(context["stableId"] as? String, engine.stableID)
        XCTAssertEqual(context["platform"] as? String, expectedPlatform)

        XCTAssertFalse(engine.pushAsksEnabled, "updated from the token response")
        let reloaded = TestEnv.makeEngine(directory: TestEnv.directory(), preferences: preferences)
        XCTAssertFalse(reloaded.pushAsksEnabled, "cached across launches")
        XCTAssertEqual(reloaded.pushToken, "ab01", "token cached across launches")
    }

    func testTokenIsNotResentUnlessSomethingChanged() async {
        MockURLProtocol.setHandler { _ in MockResponse(status: 200, body: Data("{\"asks\": true}".utf8)) }
        let engine = TestEnv.makeEngine(directory: TestEnv.directory())
        await engine.postPushToken(authorization: "authorized", environment: .sandbox)
        XCTAssertEqual(MockURLProtocol.requests.count, 0, "no token, nothing to send")

        engine.storePushToken("aa")
        await engine.postPushToken(authorization: "authorized", environment: .sandbox)
        await engine.postPushToken(authorization: "authorized", environment: .sandbox)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)

        await engine.postPushToken(authorization: "denied", environment: .sandbox)
        XCTAssertEqual(MockURLProtocol.requests.count, 2, "authorization change is re-sent")

        engine.storePushToken("aa")
        await engine.postPushToken(authorization: "denied", environment: .sandbox)
        XCTAssertEqual(MockURLProtocol.requests.count, 2, "same token again is a no-op")

        engine.storePushToken("bb")
        await engine.postPushToken(authorization: "denied", environment: .sandbox)
        XCTAssertEqual(MockURLProtocol.requests.count, 3, "new token is sent")
    }

    func testFailedRegistrationIsRetried() async {
        MockURLProtocol.setHandler(nil)
        let engine = TestEnv.makeEngine(directory: TestEnv.directory())
        engine.storePushToken("aa")
        await engine.postPushToken(authorization: "authorized", environment: .production)
        MockURLProtocol.setHandler { _ in MockResponse(status: 200, body: Data("{\"asks\": true}".utf8)) }
        await engine.postPushToken(authorization: "authorized", environment: .production)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }

    func testDeleteToken() async throws {
        MockURLProtocol.setHandler { _ in MockResponse(status: 204) }
        let preferences = TestEnv.preferences()
        let engine = TestEnv.makeEngine(directory: TestEnv.directory(), preferences: preferences)
        engine.storePushToken("cafe")
        try await engine.deletePushToken()
        let request = try XCTUnwrap(MockURLProtocol.requests.last)
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.url.path, "/v1/push/token")
        XCTAssertEqual(try json(request) as NSDictionary, ["token": "cafe"] as NSDictionary)
        XCTAssertNil(engine.pushToken)
        XCTAssertNil(preferences.string(.pushToken))
    }

    func testPreferences() async throws {
        MockURLProtocol.setHandler { request in
            if request.method == "PUT" { return MockResponse(status: 200, body: Data("{\"asks\": false}".utf8)) }
            return MockResponse(status: 200, body: Data("{\"asks\": true, \"registered\": true}".utf8))
        }
        let engine = TestEnv.makeEngine(directory: TestEnv.directory())
        try await engine.setPushAsks(false)
        let put = try XCTUnwrap(MockURLProtocol.requests.last)
        XCTAssertEqual(put.method, "PUT")
        XCTAssertEqual(put.url.path, "/v1/push/preferences")
        XCTAssertEqual(try json(put) as NSDictionary, ["asks": false] as NSDictionary)
        XCTAssertFalse(engine.pushAsksEnabled)

        try await engine.refreshPushPreferences()
        XCTAssertEqual(MockURLProtocol.requests.last?.method, "GET")
        XCTAssertTrue(engine.pushAsksEnabled)
    }

    func testStatusUpdatePreference() async throws {
        MockURLProtocol.setHandler { request in
            if request.method == "PUT" { return MockResponse(status: 200, body: Data("{\"asks\": true, \"updates\": false}".utf8)) }
            return MockResponse(status: 200, body: Data("{\"asks\": true, \"updates\": true, \"registered\": true}".utf8))
        }
        let preferences = TestEnv.preferences()
        let engine = TestEnv.makeEngine(directory: TestEnv.directory(), preferences: preferences)
        XCTAssertTrue(engine.pushUpdatesEnabled, "defaults to on")
        try await engine.setPushUpdates(false)
        let put = try XCTUnwrap(MockURLProtocol.requests.last)
        XCTAssertEqual(put.url.path, "/v1/push/preferences")
        XCTAssertEqual(try json(put) as NSDictionary, ["updates": false] as NSDictionary, "the campaign switch is left alone")
        XCTAssertFalse(engine.pushUpdatesEnabled)
        XCTAssertTrue(engine.pushAsksEnabled)
        XCTAssertFalse(TestEnv.makeEngine(directory: TestEnv.directory(), preferences: preferences).pushUpdatesEnabled, "cached across launches")

        try await engine.refreshPushPreferences()
        XCTAssertTrue(engine.pushUpdatesEnabled)
    }

    func testStatusUpdateOpened() async throws {
        MockURLProtocol.setHandler { _ in MockResponse(status: 204) }
        let engine = TestEnv.makeEngine(directory: TestEnv.directory())
        await engine.markUpdateOpened("upn_1")
        let request = try XCTUnwrap(MockURLProtocol.requests.last)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.path, "/v1/updates/upn_1/opened")
    }

    func testOpenedBody() async throws {
        MockURLProtocol.setHandler { _ in MockResponse(status: 204) }
        let engine = TestEnv.makeEngine(directory: TestEnv.directory())
        await engine.markPushOpened("dlv_1", action: "open")
        await engine.markPushOpened("dlv_1", action: "dismiss")
        let requests = MockURLProtocol.requests
        XCTAssertEqual(requests.map(\.url.path), ["/v1/push/deliveries/dlv_1/opened", "/v1/push/deliveries/dlv_1/opened"])
        XCTAssertEqual(try json(requests[0]) as NSDictionary, ["action": "open"] as NSDictionary)
        XCTAssertEqual(try json(requests[1]) as NSDictionary, ["action": "dismiss"] as NSDictionary)
    }

    func testAnswerBodies() async throws {
        MockURLProtocol.setHandler { _ in MockResponse(status: 200, body: Data("{\"ok\": true, \"threadId\": null}".utf8)) }
        let engine = TestEnv.makeEngine(directory: TestEnv.directory())

        try await engine.answerPush("dlv_1", answer: PushAnswer(value: .int(4), text: "Optional comment"))
        var body = try json(MockURLProtocol.requests.last)
        XCTAssertEqual(MockURLProtocol.requests.last?.url.path, "/v1/push/deliveries/dlv_1/answer")
        XCTAssertEqual(body["value"] as? Int, 4)
        XCTAssertEqual(body["text"] as? String, "Optional comment")
        XCTAssertNotNil(body["context"] as? [String: Any])

        try await engine.answerPush("dlv_2", answer: PushAnswer(value: .string("yes")))
        body = try json(MockURLProtocol.requests.last)
        XCTAssertEqual(body["value"] as? String, "yes")
        XCTAssertNil(body["text"])

        try await engine.answerPush("dlv_3", answer: PushAnswer(value: nil, text: "Free text"))
        body = try json(MockURLProtocol.requests.last)
        XCTAssertNil(body["value"], "value is omitted for text answers")
        XCTAssertEqual(body["text"] as? String, "Free text")
    }

    func testOfflineActionAnswerIsQueuedAndFlushed() async throws {
        MockURLProtocol.setHandler(nil)
        let engine = TestEnv.makeEngine(directory: TestEnv.directory())
        try await engine.answerPush("dlv_1", answer: PushAnswer(value: .string("no")), queueOnFailure: true)
        XCTAssertEqual(engine.pendingPushAnswers, [PendingPushAnswer(deliveryID: "dlv_1", value: .string("no"), text: nil)])

        do {
            try await engine.answerPush("dlv_2", answer: PushAnswer(value: .int(2)))
            XCTFail("without queueing the error surfaces")
        } catch {
            XCTAssertEqual(error as? ShipKitError, .offline)
        }

        MockURLProtocol.setHandler { _ in MockResponse(status: 200, body: Data("{\"ok\": true}".utf8)) }
        await engine.flushPushAnswers()
        XCTAssertEqual(MockURLProtocol.requests.last?.url.path, "/v1/push/deliveries/dlv_1/answer")
        XCTAssertEqual(try json(MockURLProtocol.requests.last)["value"] as? String, "no")
        XCTAssertTrue(engine.pendingPushAnswers.isEmpty)
    }

    func testFetchDelivery() async throws {
        MockURLProtocol.setHandler { _ in
            MockResponse(status: 200, body: Data("""
            {"delivery":{"id":"dlv_5","kind":"feedback","title":"t","body":"b","question":null,"feedbackPrompt":"Tell us more","url":null,"answered":false}}
            """.utf8))
        }
        let engine = TestEnv.makeEngine(directory: TestEnv.directory())
        let payload = try await engine.pushDelivery("dlv_5")
        XCTAssertEqual(MockURLProtocol.requests.last?.method, "GET")
        XCTAssertEqual(MockURLProtocol.requests.last?.url.path, "/v1/push/deliveries/dlv_5")
        XCTAssertEqual(payload.kind, .feedback)
        XCTAssertEqual(payload.feedbackPrompt, "Tell us more")
    }
}
