import XCTest
@testable import ShipKit

final class ReminderTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let policy = VersionInfo.Reminder(everyLaunches: 3, everyDays: 2, maxPerVersion: 3, allowSkip: true)

    private func days(_ value: Double) -> TimeInterval { value * 86_400 }

    func testFirstReminderShowsImmediately() {
        XCTAssertTrue(ReminderScheduler.shouldShow(target: "2.5.0", policy: policy, state: ReminderState(), now: start))
    }

    func testRequiresBothLaunchesAndDays() {
        var state = ReminderState()
        ReminderScheduler.recordShown(target: "2.5.0", state: &state, now: start)

        ReminderScheduler.recordLaunch(&state)
        ReminderScheduler.recordLaunch(&state)
        XCTAssertFalse(ReminderScheduler.shouldShow(target: "2.5.0", policy: policy, state: state, now: start + days(5)), "only 2 launches")

        ReminderScheduler.recordLaunch(&state)
        XCTAssertFalse(ReminderScheduler.shouldShow(target: "2.5.0", policy: policy, state: state, now: start + days(1)), "only 1 day")
        XCTAssertTrue(ReminderScheduler.shouldShow(target: "2.5.0", policy: policy, state: state, now: start + days(2)))
    }

    func testLaunchCounterResetsWhenShown() {
        var state = ReminderState()
        ReminderScheduler.recordShown(target: "2.5.0", state: &state, now: start)
        for _ in 0..<3 { ReminderScheduler.recordLaunch(&state) }
        ReminderScheduler.recordShown(target: "2.5.0", state: &state, now: start + days(3))
        XCTAssertEqual(state.launchesSinceShown, 0)
        XCTAssertEqual(state.shownCount["2.5"], 2)
        XCTAssertFalse(ReminderScheduler.shouldShow(target: "2.5.0", policy: policy, state: state, now: start + days(10)))
    }

    func testMaxPerVersion() {
        var state = ReminderState()
        var now = start
        for _ in 0..<3 {
            XCTAssertTrue(ReminderScheduler.shouldShow(target: "2.5.0", policy: policy, state: state, now: now))
            ReminderScheduler.recordShown(target: "2.5.0", state: &state, now: now)
            for _ in 0..<3 { ReminderScheduler.recordLaunch(&state) }
            now += days(3)
        }
        XCTAssertFalse(ReminderScheduler.shouldShow(target: "2.5.0", policy: policy, state: state, now: now))
        XCTAssertTrue(ReminderScheduler.shouldShow(target: "2.6.0", policy: policy, state: state, now: now), "a new target starts over")
    }

    func testSkipThisVersion() {
        var state = ReminderState()
        ReminderScheduler.recordSkip(target: "2.5.0", state: &state)
        XCTAssertFalse(ReminderScheduler.shouldShow(target: "2.5", policy: policy, state: state, now: start))
        XCTAssertTrue(ReminderScheduler.shouldShow(target: "2.5.1", policy: policy, state: state, now: start))
    }

    func testSkipIgnoredWhenServerDisallowsIt() {
        var state = ReminderState()
        ReminderScheduler.recordSkip(target: "2.5.0", state: &state)
        let noSkip = VersionInfo.Reminder(everyLaunches: 1, allowSkip: false)
        XCTAssertTrue(ReminderScheduler.shouldShow(target: "2.5.0", policy: noSkip, state: state, now: start))
    }

    func testWithoutPolicyShowsOncePerLaunchAtMost() {
        var state = ReminderState()
        ReminderScheduler.recordShown(target: "2.5.0", state: &state, now: start)
        XCTAssertFalse(ReminderScheduler.shouldShow(target: "2.5.0", policy: nil, state: state, now: start))
        ReminderScheduler.recordLaunch(&state)
        XCTAssertTrue(ReminderScheduler.shouldShow(target: "2.5.0", policy: nil, state: state, now: start))
    }

    func testWhatsNewShownOnceOnMatchingVersion() {
        let whatsNew = VersionInfo.WhatsNew(version: "2.4.0", items: ["Dark mode"])
        var state = ReminderState()
        XCTAssertFalse(ReminderScheduler.shouldShowWhatsNew(whatsNew, running: AppVersion("2.3.0"), state: state))
        XCTAssertTrue(ReminderScheduler.shouldShowWhatsNew(whatsNew, running: AppVersion("2.4", build: "311"), state: state))
        ReminderScheduler.recordWhatsNewSeen("2.4.0", state: &state)
        XCTAssertFalse(ReminderScheduler.shouldShowWhatsNew(whatsNew, running: AppVersion("2.4.0"), state: state))
        XCTAssertFalse(ReminderScheduler.shouldShowWhatsNew(.init(version: "2.4.0", items: []), running: AppVersion("2.4.0"), state: ReminderState()))
    }
}
