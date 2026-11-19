import Foundation
import os
import UIKit

private let engineBox = OSAllocatedUnfairLock<Engine?>(initialState: nil)

/// Entry point for remote settings, feature flags, version enforcement and in-app feedback.
public enum ShipKit {
    public static let sdkVersion = "1.2.0"

    static var engine: Engine? { engineBox.withLock { $0 } }

    /// Appearance used by all ShipKit views.
    @MainActor public static var theme = ShipKitTheme()

    /// Behaviour and copy of the ShipKit views.
    @MainActor public static var config = ShipKitConfig() {
        didSet { ShipKitModel.shared.configDidChange() }
    }

    // MARK: - Setup

    /// Configures the SDK. Call once, as early as possible (e.g. in your `App` initializer).
    ///
    /// Reads are served immediately from the disk cache or bundled defaults; the network refresh
    /// happens in the background and never delays launch.
    @MainActor
    public static func configure(with clientKey: String, _ configure: (inout ShipKitOptions) -> Void = { _ in }) {
        var options = ShipKitOptions()
        configure(&options)
        if options.debugTools.isEnabled, let override = apiURLOverride() { options.apiURL = override }

        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = options.requestTimeout
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        sessionConfiguration.waitsForConnectivity = false

        let engine = Engine(
            configuration: .init(
                clientKey: clientKey,
                options: options,
                appInfo: .main,
                preferences: Preferences(defaults: .standard),
                directory: SnapshotStore.defaultDirectory,
                session: URLSession(configuration: sessionConfiguration)
            ),
            onChange: { Task { @MainActor in ShipKitModel.shared.reload() } }
        )
        install(engine)
        engine.recordLaunch()
        LifecycleObserver.shared.attach(engine)
        PushCoordinator.shared.attach(engine)
        engine.noteRefreshScheduled()
        Task { await engine.refresh() }
    }

    /// Configures ShipKit with a fixed snapshot and no networking, for previews, UI tests and unit tests.
    @MainActor
    public static func configureForTesting(snapshot: ShipKitSnapshot, options: ShipKitOptions = ShipKitOptions()) {
        let suite = "dev.shipkit.testing"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let engine = Engine(
            configuration: .init(
                clientKey: "skc_test",
                options: options,
                appInfo: .main,
                preferences: Preferences(defaults: defaults),
                directory: FileManager.default.temporaryDirectory.appendingPathComponent("ShipKitTesting", isDirectory: true),
                session: URLSession(configuration: .ephemeral),
                useKeychain: false,
                networkEnabled: false,
                persistent: false
            ),
            testSnapshot: snapshot,
            onChange: { Task { @MainActor in ShipKitModel.shared.reload() } }
        )
        install(engine)
        LifecycleObserver.shared.detach()
        PushCoordinator.shared.detach()
    }

    @MainActor
    private static func install(_ engine: Engine) {
        engineBox.withLock { $0 = engine }
        ShipKitModel.shared.resetSession()
        ShipKitModel.shared.reload()
    }

    static func apiURLOverride(environment: [String: String] = ProcessInfo.processInfo.environment, defaults: UserDefaults = .standard) -> URL? {
        let candidates = [environment[ShipKitDefaults.apiURLEnvironmentKey], defaults.string(forKey: ShipKitDefaults.apiURLDefaultsKey)]
        for candidate in candidates {
            if let text = candidate?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
               let url = URL(string: text), url.scheme != nil {
                return url
            }
        }
        return nil
    }

    /// Stable, anonymous install identifier sent as `X-ShipKit-Stable-Id`.
    public static var installID: String? { engine?.stableID }

    // MARK: - Identity

    /// Associates the install with your user. Values persist across launches and are sent with every request context.
    public static func identify(
        userID: String? = nil,
        email: String? = nil,
        name: String? = nil,
        paymentMonthly: Double? = nil,
        attributes: [String: ShipKitValue] = [:]
    ) {
        guard let engine else { return notConfigured() }
        let identity = Identity(userId: userID, email: email, name: name, paymentMonthly: paymentMonthly, attributes: attributes)
        Task { await engine.identify(identity) }
    }

    // MARK: - Settings & flags

    /// Returns a remote setting. Never blocks: values come from memory (cache, bundled defaults, then `default`).
    public static func setting<T: Decodable>(_ key: String, default defaultValue: T) -> T {
        guard let value = engine?.settingValue(key) else { return defaultValue }
        guard let typed = value.decode(T.self) else {
            ShipKitLog.error("Setting \(key) has value \(value.jsonText), which isn't a \(T.self). Using the default.")
            return defaultValue
        }
        return typed
    }

    /// Raw JSON value of a setting, or `nil` when unknown.
    public static func settingValue(_ key: String) -> ShipKitValue? {
        engine?.settingValue(key)
    }

    /// `true` when the flag is on (a `true` boolean or any non-empty, non-`off` variant).
    public static func isEnabled(_ flag: String) -> Bool {
        engine?.isEnabled(flag) ?? false
    }

    /// The flag's variant name, or `default` when the flag is unknown.
    public static func variant(_ flag: String, default defaultValue: String = "control") -> String {
        engine?.variant(flag, default: defaultValue) ?? defaultValue
    }

    // MARK: - Refresh & version

    /// Fetches a fresh snapshot now, ignoring the refresh interval, then retries queued feedback.
    public static func refresh() async {
        await engine?.refresh()
    }

    /// The version status, after the first refresh of this session has completed.
    public static func versionStatus() async -> VersionStatus {
        await engine?.versionStatus() ?? .ok
    }

    /// The version status from what is in memory right now.
    public static var currentVersionStatus: VersionStatus {
        engine?.currentVersionStatus ?? .ok
    }

    /// Unread developer replies across this install's feedback threads.
    public static func unreadCount() async -> Int {
        await engine?.refreshUnread() ?? 0
    }

    private static func notConfigured() {
        ShipKitLog.error("ShipKit.configure(with:) has not been called.")
    }
}

@MainActor
final class LifecycleObserver {
    static let shared = LifecycleObserver()
    private var token: NSObjectProtocol?

    func attach(_ engine: Engine) {
        detach()
        token = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { await engine.refreshIfNeeded() }
        }
    }

    func detach() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}
