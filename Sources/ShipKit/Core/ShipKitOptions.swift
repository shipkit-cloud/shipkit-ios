import Foundation
@preconcurrency import UserNotifications

public enum ShipKitDefaults {
    /// Used when `ShipKitOptions.apiURL` is not set.
    public static let apiURL = URL(string: "https://api.shipkit.cloud")!

    /// Process environment variable that overrides the API URL, handy for local backends and UI tests.
    public static let apiURLEnvironmentKey = "SHIPKIT_API_URL"

    /// Launch argument / UserDefaults key that overrides the API URL (`-ShipKitAPIURL http://...`).
    public static let apiURLDefaultsKey = "ShipKitAPIURL"

    /// UserDefaults key holding a simulated marketing version (set by `DebugView`). Only read when
    /// `ShipKitOptions.debugTools` is enabled, like the three keys above and below.
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

/// Controls the developer tools: `ShipKit.DebugView`, version simulation, local setting and flag
/// overrides, and the API URL override.
public enum ShipKitDebugTools: Sendable, Equatable {
    /// On in debug builds, off in release builds.
    case automatic
    /// On in every build. Use for internal or TestFlight builds only: with these tools anyone
    /// holding the device can get past version rules.
    case enabled
    case disabled

    var isEnabled: Bool {
        switch self {
        case .enabled: return true
        case .disabled: return false
        case .automatic:
            #if DEBUG
            return true
            #else
            return false
            #endif
        }
    }
}

public enum ShipKitTelemetry: Sendable, Equatable {
    /// One ping per day plus flag exposure counts.
    case on
    case off
}

public struct ShipKitOptions: Sendable {
    public var apiURL: URL = ShipKitDefaults.apiURL
    /// Base64 of the raw 32-byte Ed25519 public key from the dashboard. When set, a snapshot is only
    /// accepted if the server signed it for this install and this exact request; anything unsigned,
    /// edited, replayed or answering a changed request is rejected and the cached snapshot stays in
    /// effect. Without it, version rules can be tampered with in transit.
    public var signingKey: String?
    /// How long the app may go without a successful version check before it is held on a
    /// "connect to continue" screen (`VersionStatus.checkRequired`). `nil`, the default, never
    /// holds the app: with no network it runs on the last snapshot it has, which also means that
    /// blocking the network skips new version rules. Set it (for example `7 * 86_400`) when a
    /// required update must not be avoidable that way.
    public var versionCheckMaxAge: TimeInterval?
    /// Developer tools. Off in release builds unless you opt in.
    public var debugTools: ShipKitDebugTools = .automatic
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

/// What a status update push is about.
public enum ShipKitUpdateTarget: Sendable, Equatable {
    /// A feedback conversation. `nil` when the push named none; show the inbox.
    case feedbackThread(id: String?)
    /// A feature request. `nil` when the push named none; show the request board.
    case featureRequest(id: String?)
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
    /// Opens what a tapped status update push is about. Defaults to presenting the feedback
    /// conversation or the feature request in a sheet; set it to show them in your own navigation.
    public var openUpdate: (@MainActor @Sendable (ShipKitUpdateTarget) -> Void)?

    public init() {}

    var resolvedEnvironment: ShipKitPushEnvironment { environment ?? .automatic }
}
