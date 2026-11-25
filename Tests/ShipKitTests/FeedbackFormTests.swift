import XCTest
@testable import ShipKit

final class FeedbackFormTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private func servedForm() throws -> FeedbackForm {
        let data = try XCTUnwrap(TestEnv.fixture("snapshot-form", ext: "json"), "Fixtures/snapshot-form.json missing")
        return try XCTUnwrap(try ShipKitSnapshot(jsonData: data).feedbackForm)
    }

    func testDecodesServedFormAndSkipsWhatItDoesNotKnow() throws {
        let form = try servedForm()
        XCTAssertEqual(form.rev, "c91db483")
        XCTAssertTrue(form.isCustom)
        XCTAssertEqual(form.defaultCategory, .idea)
        XCTAssertEqual(form.submitLabel, "Senden")
        XCTAssertEqual(form.thanksTitle, "Danke!")
        XCTAssertNil(form.thanksMessage)
        // Malformed elements are dropped; a field type from a newer ShipKit is kept but hidden.
        XCTAssertEqual(form.fields.map(\.id), ["rating", "f_order1", "f_area1", "f_date1", "message", "email", "screenshots"])
        XCTAssertEqual(form.fields[3].kind, .unknown("date"))
        XCTAssertEqual(form.visibleFields.map(\.id), ["rating", "f_order1", "f_area1", "message", "email", "screenshots"])
        XCTAssertEqual(form.fields[2].options.map(\.label), ["Zahlung", "Lieferung"])
        XCTAssertEqual(form.fields[1].maxLength, 20)
        XCTAssertTrue(form.fields[5].updates)
        XCTAssertEqual(form.fields[6].max, 2)
        XCTAssertNil(form.fields[4].label, "built-in label left to the SDK")
    }

    func testSnapshotsWithoutAFormStillDecode() throws {
        let snapshot = try ShipKitSnapshot(jsonData: TestEnv.snapshotJSON(status: "ok"))
        XCTAssertNil(snapshot.feedbackForm)
        let broken = try ShipKitSnapshot(jsonData: Data(#"{"release":1,"settings":{},"flags":{},"feedbackForm":"nonsense"}"#.utf8))
        XCTAssertNil(broken.feedbackForm)
        XCTAssertEqual(broken.release, 1)
    }

    func testStandardFormFollowsConfig() {
        var config = ShipKitConfig.Feedback()
        XCTAssertEqual(FeedbackForm.standard(config).fields.map(\.id), ["category", "rating", "message", "screenshots", "email"])
        XCTAssertFalse(FeedbackForm.standard(config).isCustom)
        config.showsRating = false
        config.asksForEmail = false
        config.attachScreenshot = false
        XCTAssertEqual(FeedbackForm.standard(config).fields.map(\.id), ["category", "message"])
        config.attachScreenshot = true
        config.maxAttachments = 5
        XCTAssertEqual(FeedbackForm.standard(config).fields.last?.max, 5)
    }

    func testResolveFallsBackAndRespectsScreenshotSetting() throws {
        let config = ShipKitConfig.Feedback()
        XCTAssertFalse(FeedbackForm.resolve(nil, config: config).isCustom)
        let onlyUnknown = FeedbackForm(rev: "x", fields: [.init(id: "f_x1yy", kind: .unknown("date"))])
        XCTAssertFalse(FeedbackForm.resolve(onlyUnknown, config: config).isCustom, "nothing to show means the standard form")
        var noScreens = config
        noScreens.attachScreenshot = false
        let resolved = FeedbackForm.resolve(try servedForm(), config: noScreens)
        XCTAssertTrue(resolved.isCustom)
        XCTAssertFalse(resolved.fields.contains { $0.kind == .screenshots })
    }

    func testRequiredFieldsContentAndEmail() throws {
        let form = try servedForm()
        var values = FeedbackForm.Values()
        XCTAssertEqual(form.missingRequired(values), ["rating"], "the unknown required field never blocks sending")
        XCTAssertFalse(form.hasContent(values))
        values.texts["email"] = "ana@example.com"
        XCTAssertFalse(form.hasContent(values), "an email alone is not feedback")
        values.ratings["rating"] = 4
        XCTAssertEqual(form.missingRequired(values), [])
        XCTAssertTrue(form.hasContent(values))

        let standard = FeedbackForm.standard(ShipKitConfig.Feedback())
        var plain = FeedbackForm.Values()
        plain.ratings["rating"] = 5
        XCTAssertEqual(standard.missingRequired(plain), ["message"], "the standard form still needs a message")
        plain.texts["message"] = "   "
        XCTAssertEqual(standard.missingRequired(plain), ["message"])

        XCTAssertTrue(FeedbackForm.isValidEmail(" ana@example.com "))
        for bad in ["ana", "ana@", "@example.com", "ana@example", "ana @example.com", "ana@@example.com", "ana@.com"] {
            XCTAssertFalse(FeedbackForm.isValidEmail(bad), bad)
        }
    }

    func testAnswersCoverOnlyCustomFields() throws {
        let form = try servedForm()
        var values = FeedbackForm.Values()
        values.ratings["rating"] = 4
        values.texts["message"] = "Great"
        values.texts["f_order1"] = "  A-1042  "
        values.choices["f_area1"] = "o_2"
        XCTAssertEqual(form.answers(values), [
            FeedbackAnswer(id: "f_order1", type: "text", label: "Bestellnummer", value: .string("A-1042")),
            FeedbackAnswer(id: "f_area1", type: "choice", label: "Bereich", value: .string("o_2"))
        ])
    }

    func testSubmissionCarriesAnswersAndOldQueueItemsStillDecode() async throws {
        MockURLProtocol.setHandler { _ in
            MockResponse(status: 200, body: Data(#"{"thread":{"id":"fb_1","category":"idea","status":"new","preview":"A-1042","unread":0}}"#.utf8))
        }
        let engine = TestEnv.makeEngine(directory: TestEnv.directory())
        let answers = [FeedbackAnswer(id: "f_order1", type: "text", label: "Order", value: .string("A-1042"))]
        _ = try await engine.submitFeedback(category: .idea, rating: nil, message: "", email: "ana@example.com", images: [], answers: answers, formRev: "c91db483")
        let body = try XCTUnwrap(MockURLProtocol.requests.last?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["formRev"] as? String, "c91db483")
        let sent = try XCTUnwrap(json["answers"] as? [[String: Any]])
        XCTAssertEqual(sent.first?["id"] as? String, "f_order1")
        XCTAssertEqual(sent.first?["value"] as? String, "A-1042")
        XCTAssertEqual(json["email"] as? String, "ana@example.com")

        // The standard form keeps the body older SDKs sent: no answers, no formRev.
        _ = try await engine.submitFeedback(category: .bug, rating: 3, message: "Crash", email: nil, images: [])
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: MockURLProtocol.requests.last?.body ?? Data()) as? [String: Any])
        XCTAssertNil(plain["answers"])
        XCTAssertNil(plain["formRev"])

        // A report queued by SDK 1.2 has neither key.
        let legacy = Data("""
        {"id":"q1","createdAt":"2026-11-01T10:00:00Z","pendingImages":[],
         "submission":{"category":"bug","rating":null,"message":"Old","email":null,"attachments":[],
         "context":{"stableId":"abc","appVersion":"1.0","build":"1","platform":"ios","attributes":{}}}}
        """.utf8)
        let item = try JSON.decoder.decode(PendingFeedback.self, from: legacy)
        XCTAssertEqual(item.submission.message, "Old")
        XCTAssertNil(item.submission.answers)
        XCTAssertNil(item.submission.formRev)
    }
}
