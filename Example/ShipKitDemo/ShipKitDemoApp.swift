import ShipKit
import SwiftUI
import UserNotifications

@main
struct ShipKitDemoApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        let environment = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        let clientKey = environment["SHIPKIT_CLIENT_KEY"].nonEmpty
            ?? defaults.string(forKey: "ShipKitClientKey").nonEmpty
            ?? "skc_demo"

        ShipKit.configure(with: clientKey) { options in
            options.apiURL = URL(string: environment["SHIPKIT_API_URL"].nonEmpty ?? "http://localhost:8787")!
            options.signingKey = environment["SHIPKIT_SIGNING_KEY"].nonEmpty
            options.defaultsResource = "ShipKitDefaults"
            options.refresh = .onForeground(minInterval: 60)
            options.telemetry = .on
        }
        ShipKit.config.feedback.shakeToReport = true
        ShipKit.theme.primaryColor = .indigo
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .shipKitGate()
        }
        #if os(macOS)
        // The Mac has no shake gesture: feedback lives in the Help menu instead.
        .commands { ShipKitFeedbackCommands(shortcut: KeyboardShortcut("f", modifiers: [.command, .shift])) }
        #endif
    }
}

// Apple TV has no push campaigns, so the tvOS app needs no delegate.
#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Set before returning so a tap that launched the app is delivered.
        UNUserNotificationCenter.current().delegate = ShipKit.notificationDelegate
        // Doesn't prompt. Refreshes the token when notifications were allowed earlier.
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        ShipKit.setPushToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Remote notification registration failed: \(error.localizedDescription)")
    }
}
#elseif os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = ShipKit.notificationDelegate
        // Doesn't prompt. Refreshes the token when notifications were allowed earlier.
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        ShipKit.setPushToken(deviceToken)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Expected until the target is signed with the push entitlement (see project.yml).
        print("Remote notification registration failed: \(error.localizedDescription)")
    }
}
#endif

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
