import XCTest
@testable import ShipKit

final class VersionTests: XCTestCase {
    func testNumericComponentsCompareNumerically() {
        XCTAssertLessThan(AppVersion("2.4.0"), AppVersion("2.10.0"))
        XCTAssertLessThan(AppVersion("1.9.9"), AppVersion("2.0.0"))
        XCTAssertGreaterThan(AppVersion("10.0"), AppVersion("9.99.99"))
    }

    func testMissingComponentsAreZero() {
        XCTAssertEqual(AppVersion("2.4"), AppVersion("2.4.0"))
        XCTAssertEqual(AppVersion("2"), AppVersion("2.0.0"))
        XCTAssertLessThan(AppVersion("2.4"), AppVersion("2.4.1"))
    }

    func testPrereleaseSortsBeforeRelease() {
        XCTAssertLessThan(AppVersion("2.4.0-beta.1"), AppVersion("2.4.0"))
        XCTAssertLessThan(AppVersion("2.4.0-beta.2"), AppVersion("2.4.0-beta.10"))
        XCTAssertLessThan(AppVersion("2.4.0-alpha"), AppVersion("2.4.0-beta"))
        XCTAssertGreaterThan(AppVersion("2.4.1-beta"), AppVersion("2.4.0"))
    }

    func testBuildComparedOnlyWhenBothHaveOne() {
        XCTAssertLessThan(AppVersion("2.4.0", build: "311"), AppVersion("2.4.0", build: "312"))
        XCTAssertLessThan(AppVersion("2.4.0", build: "99"), AppVersion("2.4.0", build: "100"))
        XCTAssertEqual(AppVersion("2.4.0", build: "311"), AppVersion("2.4.0"))
        XCTAssertLessThan(AppVersion("2.3.9", build: "999"), AppVersion("2.4.0", build: "1"))
    }

    func testPlusBuildSyntaxAndPrefix() {
        let version = AppVersion("v2.4.0+311")
        XCTAssertEqual(version.components, [2, 4, 0])
        XCTAssertEqual(version.build, "311")
        XCTAssertLessThan(AppVersion("2.4.0+311"), AppVersion("2.4.0+400"))
    }

    func testEvaluatorTrustsServerForSameRelease() {
        let info = VersionInfo(status: .blocked, min: "2.0.0")
        let running = AppVersion("2.4.0", build: "311")
        XCTAssertEqual(VersionEvaluator.status(for: info, fetchedFor: running, running: running), .blocked(info))
    }

    func testEvaluatorReDerivesAfterAppUpdate() {
        let required = VersionInfo(status: .required, min: "2.5.0", recommended: "2.6.0")
        let fetchedFor = AppVersion("2.4.0", build: "311")
        XCTAssertEqual(
            VersionEvaluator.status(for: required, fetchedFor: fetchedFor, running: AppVersion("2.5.0", build: "320")),
            .updateRecommended(required)
        )
        XCTAssertEqual(
            VersionEvaluator.status(for: required, fetchedFor: fetchedFor, running: AppVersion("2.6.0", build: "330")),
            .ok
        )
        let blocked = VersionInfo(status: .blocked, min: "2.0.0")
        XCTAssertEqual(VersionEvaluator.status(for: blocked, fetchedFor: fetchedFor, running: AppVersion("2.4.1", build: "312")), .ok)
    }

    func testMaintenanceAlwaysApplies() {
        let info = VersionInfo(status: .maintenance, maintenance: .init(message: "Back soon"))
        XCTAssertEqual(
            VersionEvaluator.status(for: info, fetchedFor: AppVersion("1.0"), running: AppVersion("9.0")),
            .maintenance(info)
        )
    }

    func testNoInfoIsOK() {
        XCTAssertEqual(VersionEvaluator.status(for: nil, fetchedFor: nil, running: AppVersion("1.0")), .ok)
    }
}
