import Foundation
@preconcurrency import UserNotifications

public enum ShipKitDefaults {
    /// Used when `ShipKitOptions.apiURL` is not set.
    public static let apiURL = URL(string: "https://api.shipkit.cloud")!

    /// Process environment variable that overrides the API URL, handy for local backends and UI tests.
    public static let apiURLEnvironmentKey = "SHIPKIT_API_URL"

    /// Launch argument / UserDefaults key that overrides the API URL (`-ShipKitAPIURL http://...`).
    public static let apiURLDefaultsKey = "ShipKitAPIURL"

    /// UserDefaults key holding a simulated marketing version (set by `DebugView`).
    public static let simulatedVersionKey = "ShipKitSimulatedAppVersion"

    /// Launch argument that simulates a marketing version (`-ShipKitSimulateVersion 1.0.0`).
    public static let simulateVersionArgumentKey = "ShipKitSimulateVersion"
}

public enum ShipKitRefreshPolicy: Sendable, Equatable {
    /// Refresh on launch and whenever the app returns to the foreground, at most once per `minInterval` seconds.
    case onForeground(minInterval: TimeInterval)
    /// Refresh on launch only; call `ShipKit.refresh()` for more.
    case manual
}

public enum ShipKitTelemetry: Sendable, Equatable {
    /// One ping per day plus flag exposure counts.
    case on
    case off
}

public struct ShipKitOptions: Sendable {
    public var apiURL: URL = ShipKitDefaults.apiURL
    /// Base64 of the raw 32-byte Ed25519 public key from the dashboard. When set, unsigned or
    /// tampered snapshots are rejected and the cached snapshot stays in effect.
    public var signingKey: String?
    /// Fallback values used before the first snapshot arrives and for keys missing from it.
    public var defaults: [String: ShipKitValue] = [:]
    /// Name of a `.json` or `.plist` file in the main bundle with fallback values.
    public var defaultsResource: String?
    public var refresh: ShipKitRefreshPolicy = .onForeground(minInterval: 900)
    /// Keeps setting and flag values stable for the whole session. Fresh values apply on the next launch.
    public var lockFlagsOnLaunch: Bool = false
    public var telemetry: ShipKitTelemetry = .on
    /// Timeout for individual requests.
    public var requestTimeout: TimeInterval = 15
    /// Push notification behaviour.
    public var push = ShipKitPushOptions()

    public init() {}
}

public struct ShipKitPushOptions: Sendable {
    /// APNs environment sent with the device token. `nil` picks `sandbox` in debug builds and
    /// `production` otherwise; set it explicitly for release builds signed with development provisioning.
    public var environment: ShipKitPushEnvironment?
    /// How ShipKit pushes are shown while the app is in the foreground.
    public var foregroundPresentation: UNNotificationPresentationOptions = [.banner, .sound, .list]
    /// Opens the `url` of a tapped message push. Defaults to `UIApplication.shared.open(_:)`;
    /// set it to route deep links through your own navigation.
    public var openURL: (@MainActor @Sendable (URL) -> Void)?

    public init() {}

    var resolvedEnvironment: ShipKitPushEnvironment { environment ?? .automatic }
}
