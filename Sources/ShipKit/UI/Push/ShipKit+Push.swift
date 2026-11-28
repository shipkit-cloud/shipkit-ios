#if !os(tvOS)
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@preconcurrency import UserNotifications

extension ShipKit {
    // MARK: - Token

    /// Registers the APNs device token with ShipKit. Call it from
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    ///
    /// The token is cached and re-sent on every launch and whenever the notification
    /// authorization changes, so the backend always knows whether it can reach this install.
    public static func setPushToken(_ deviceToken: Data) {
        guard let engine else {
            ShipKitLog.error("setPushToken called before ShipKit.configure(with:).")
            return
        }
        engine.storePushToken(PushTokenEncoding.hex(deviceToken))
        Task { await PushSystem.syncToken(engine) }
    }

    /// Unregisters the device token so this install gets no more pushes (for example on sign-out).
    public static func clearPushToken() async throws {
        guard let engine else { throw ShipKitError.notConfigured }
        try await engine.deletePushToken()
    }

    /// Asks the user for permission to show notifications (alert, sound, badge), then registers
    /// for remote notifications. Returns whether permission was granted.
    ///
    /// ShipKit never calls this by itself: call it at a moment that makes sense in your app.
    @MainActor
    @discardableResult
    public static func requestPushPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            ShipKitLog.error("Notification permission request failed: \(error.localizedDescription)")
            granted = false
        }
        PlatformApp.registerForRemoteNotifications()
        if let engine { await PushSystem.syncToken(engine) }
        return granted
    }

    // MARK: - Preferences

    /// Whether this install accepts questions, feedback requests and messages from the developer.
    /// Served from cache; updated whenever the token is registered or the preference changes.
    public static var pushAsksEnabled: Bool {
        engine?.pushAsksEnabled ?? true
    }

    /// Turns developer questions, feedback requests and messages on or off for this install.
    /// `ShipKitPushAsksToggle` wraps this in a settings row.
    public static func setPushAsks(_ enabled: Bool) async throws {
        guard let engine else { throw ShipKitError.notConfigured }
        try await engine.setPushAsks(enabled)
    }

    /// Whether this install gets status updates about feedback and feature requests the user sent
    /// or voted for. Served from cache; updated whenever the token is registered or the preference changes.
    public static var pushUpdatesEnabled: Bool {
        engine?.pushUpdatesEnabled ?? true
    }

    /// Turns status update pushes on or off for this install. `ShipKitPushUpdatesToggle` wraps this
    /// in a settings row.
    public static func setPushUpdates(_ enabled: Bool) async throws {
        guard let engine else { throw ShipKitError.notConfigured }
        try await engine.setPushUpdates(enabled)
    }

    // MARK: - Handling

    /// The notification categories ShipKit registers (merged with your own when ShipKit is configured).
    /// Include them if you call `setNotificationCategories` yourself after configuring ShipKit.
    @MainActor
    public static var notificationCategories: Set<UNNotificationCategory> {
        PushCategories.make(titles: .init(
            yes: L("push.action.yes"),
            no: L("push.action.no"),
            reply: L("push.action.reply"),
            replySend: L("push.action.reply.send"),
            replyPlaceholder: L("push.action.reply.placeholder")
        ))
    }

    /// `true` when the notification was sent by ShipKit.
    public static func isShipKitNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo["shipkit"] is [String: Any]
    }

    /// Handles a tap or action on a ShipKit notification. Returns `false` for notifications that
    /// aren't ShipKit's, so you can forward every response and handle the rest yourself.
    ///
    /// A tap records the open and shows the matching UI (opens the message link, the feedback
    /// form or the question sheet). Action buttons send the answer without opening any UI.
    public static func handleNotificationResponse(_ response: UNNotificationResponse) async -> Bool {
        guard let event = responseEvent(response) else { return false }
        await PushCoordinator.shared.handle(event)
        return true
    }

    /// Completion-handler form for `userNotificationCenter(_:didReceive:withCompletionHandler:)`.
    /// Returns `false` right away when the notification isn't ShipKit's; `completionHandler` is then
    /// left to you. Otherwise ShipKit calls it on the main thread once the answer or tap is handled.
    @discardableResult
    public static func handleNotificationResponse(_ response: UNNotificationResponse, completionHandler: @escaping () -> Void) -> Bool {
        guard let event = responseEvent(response) else { return false }
        let done = MainThreadCompletion(completionHandler)
        Task {
            await PushCoordinator.shared.handle(event)
            await done.call()
        }
        return true
    }

    static func responseEvent(_ response: UNNotificationResponse) -> PushResponseEvent? {
        let content = response.notification.request.content
        guard var payload = PushPayload(userInfo: content.userInfo) else { return nil }
        if !content.title.isEmpty { payload.title = content.title }
        if !content.body.isEmpty { payload.body = content.body }
        return PushResponseEvent(
            payload: payload,
            actionIdentifier: response.actionIdentifier,
            userText: (response as? UNTextInputNotificationResponse)?.userText
        )
    }

    /// Presentation options for a ShipKit notification arriving in the foreground, or `nil` when
    /// it isn't ShipKit's. Return it from `userNotificationCenter(_:willPresent:)`.
    public static func notificationPresentationOptions(for notification: UNNotification) -> UNNotificationPresentationOptions? {
        guard isShipKitNotification(notification.request.content.userInfo) else { return nil }
        return engine?.options.push.foregroundPresentation ?? [.banner, .sound, .list]
    }

    /// A ready-made notification center delegate for apps that don't have their own:
    /// `UNUserNotificationCenter.current().delegate = ShipKit.notificationDelegate`.
    public static let notificationDelegate = ShipKitNotificationDelegate()
}

/// Shows ShipKit notifications in the foreground and handles taps and actions on them.
/// Other notifications keep the system default (not shown while the app is open).
public final class ShipKitNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    // Completion-handler forms on purpose: with the async forms the system completion runs on a
    // background thread, and UIKit aborts when an action is answered while the app is open.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(ShipKit.notificationPresentationOptions(for: notification) ?? [])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if !ShipKit.handleNotificationResponse(response, completionHandler: completionHandler) {
            completionHandler()
        }
    }
}

/// Carries a system completion handler across the async hop and calls it on the main thread.
final class MainThreadCompletion: @unchecked Sendable {
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @MainActor func call() { block() }
}

struct PushResponseEvent: Sendable {
    var payload: PushPayload
    var actionIdentifier: String
    var userText: String?
}

enum PushSystem {
    static func authorization() async -> String {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return PushAuthorization.string(settings.authorizationStatus)
    }

    static func syncToken(_ engine: Engine) async {
        guard engine.configuration.networkEnabled, engine.pushToken != nil else { return }
        let status = await authorization()
        await engine.postPushToken(authorization: status, environment: engine.options.push.resolvedEnvironment)
    }
}

@MainActor
final class PushCoordinator {
    static let shared = PushCoordinator()

    private var foregroundObserver: NSObjectProtocol?
    private var watcher: Task<Void, Never>?

    func attach(_ engine: Engine) {
        detach()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: PlatformApp.foregroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                await PushCoordinator.shared.registerCategories(onlyIfMissing: true)
                await PushSystem.syncToken(engine)
            }
        }
        Task {
            await registerCategories(onlyIfMissing: false)
            await PushSystem.syncToken(engine)
            await engine.flushPushAnswers()
        }
    }

    func detach() {
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        foregroundObserver = nil
    }

    /// Adds ShipKit's categories to whatever the app registered. Needs no permission.
    func registerCategories(onlyIfMissing: Bool) async {
        let center = UNUserNotificationCenter.current()
        let existing = await center.notificationCategories()
        if onlyIfMissing, !PushCategories.needsRegistration(existing: existing) { return }
        center.setNotificationCategories(PushCategories.merge(existing: existing, shipKit: ShipKit.notificationCategories))
    }

    func handle(_ event: PushResponseEvent) async {
        guard let engine = ShipKit.engine else {
            ShipKitLog.error("Received a ShipKit notification before ShipKit.configure(with:).")
            return
        }
        let deliveryID = event.payload.deliveryID
        switch event.actionIdentifier {
        case UNNotificationDismissActionIdentifier:
            if let deliveryID { await engine.markPushOpened(deliveryID, action: "dismiss") }
        case UNNotificationDefaultActionIdentifier:
            let updateID = event.payload.kind == .update ? event.payload.updateID : nil
            let opened = Task {
                if let deliveryID { await engine.markPushOpened(deliveryID, action: "open") }
                if let updateID { await engine.markUpdateOpened(updateID) }
            }
            await open(event.payload, engine: engine)
            await opened.value
        default:
            guard let deliveryID,
                  let answer = PushAnswer.fromAction(event.actionIdentifier, userText: event.userText) else { return }
            // Action buttons can launch the app in the background; keep it alive until the answer is out.
            let activity = BackgroundActivity.begin("ShipKit push answer")
            defer { activity.end() }
            try? await engine.answerPush(deliveryID, answer: answer, queueOnFailure: true)
        }
    }

    private func open(_ original: PushPayload, engine: Engine) async {
        var payload = original
        // The question sheet fetches missing details itself while showing a spinner.
        if payload.needsFetch, payload.kind != .question, let id = payload.deliveryID,
           let fetched = try? await engine.pushDelivery(id) {
            payload = payload.merged(with: fetched)
        }
        switch payload.kind {
        case .message?:
            guard let url = payload.url.flatMap(URL.init(string:)) else { return }
            await openURL(url, engine: engine)
        case .feedback?:
            present(.feedback(deliveryID: payload.deliveryID, prompt: payload.feedbackPrompt))
        case .question?:
            present(.question(payload))
        case .update?:
            let target: ShipKitUpdateTarget = payload.target == "request" ? .featureRequest(id: payload.ref) : .feedbackThread(id: payload.ref)
            if let handler = engine.options.push.openUpdate {
                handler(target)
            } else {
                present(.update(target))
            }
        case nil:
            break
        }
    }

    private func openURL(_ url: URL, engine: Engine) async {
        if let handler = engine.options.push.openURL {
            handler(url)
            return
        }
        await waitUntilActive()
        PlatformApp.open(url)
    }

    private func waitUntilActive() async {
        for _ in 0..<20 where !PlatformApp.isActive {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Queues the presentation. `.shipKitGate()` picks it up when mounted; otherwise it's presented
    /// over the top-most view controller once a window is ready (cold start can get here first).
    func present(_ presentation: PushPresentation) {
        let model = ShipKitModel.shared
        model.pendingPush = presentation
        watcher?.cancel()
        watcher = Task { await deliverWithoutGate() }
    }

    private func deliverWithoutGate() async {
        for attempt in 0..<60 {
            try? await Task.sleep(for: .milliseconds(attempt == 0 ? 600 : 250))
            if Task.isCancelled { return }
            let model = ShipKitModel.shared
            guard let pending = model.pendingPush, model.mountedGates == 0 else { return }
            guard PlatformApp.isActive, let host = PushPresenter.topViewController() else { continue }
            model.pendingPush = nil
            PushPresenter.present(pending, from: host)
            return
        }
    }
}

enum PushPresentation: Identifiable, Equatable, Sendable {
    case feedback(deliveryID: String?, prompt: String?)
    case question(PushPayload)
    case update(ShipKitUpdateTarget)

    var id: String {
        switch self {
        case .feedback(let deliveryID, _): return "feedback-\(deliveryID ?? "")"
        case .question(let payload): return "question-\(payload.deliveryID ?? "")"
        case .update(.feedbackThread(let id)): return "thread-\(id ?? "")"
        case .update(.featureRequest(let id)): return "request-\(id ?? "")"
        }
    }
}

#if canImport(UIKit)
@MainActor
enum PushPresenter {
    static var keyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let ordered = scenes.filter { $0.activationState == .foregroundActive } + scenes.filter { $0.activationState != .foregroundActive }
        let windows = ordered.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    static func topViewController() -> UIViewController? {
        guard var top = keyWindow?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    /// Something (usually the app's own sheet) is already presented over the root view.
    static var hasModal: Bool {
        guard let presented = keyWindow?.rootViewController?.presentedViewController else { return false }
        return !presented.isBeingDismissed
    }

    static func present(_ presentation: PushPresentation, from host: UIViewController) {
        let controller = UIHostingController(rootView: PushPresentationView(presentation: presentation))
        host.present(controller, animated: true)
    }

    /// Presents any ShipKit view as a sheet. With `compact`, it opens at half height and the view
    /// can grow it with the closure it gets.
    static func present<Content: View>(compact: Bool, from host: UIViewController, @ViewBuilder content: (_ expand: @escaping @MainActor () -> Void) -> Content) {
        let box = WeakController()
        let controller = UIHostingController(rootView: content {
            guard let sheet = box.controller?.sheetPresentationController else { return }
            sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
        })
        box.controller = controller
        if compact, let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .medium
            sheet.prefersGrabberVisible = true
        }
        host.present(controller, animated: true)
    }
}

/// Lets a hosted view reach its own controller without keeping it alive.
@MainActor
final class WeakController {
    weak var controller: UIViewController?
}

@MainActor
final class BackgroundActivity {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    static func begin(_ name: String) -> BackgroundActivity {
        let activity = BackgroundActivity()
        activity.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { activity.end() }
        }
        return activity
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#else
@MainActor
enum PushPresenter {
    static var keyWindow: NSWindow? {
        let application = NSApplication.shared
        return application.mainWindow ?? application.keyWindow ?? application.windows.first(where: \.isVisible)
    }

    static func topViewController() -> NSViewController? {
        guard var top = keyWindow?.contentViewController else { return nil }
        while let presented = top.presentedViewControllers?.last {
            top = presented
        }
        return top
    }

    /// Something (usually the app's own sheet) is already attached to the front window.
    static var hasModal: Bool {
        keyWindow?.attachedSheet != nil
    }

    static func present(_ presentation: PushPresentation, from host: NSViewController) {
        let controller = NSHostingController(rootView: PushPresentationView(presentation: presentation).skSheetSize())
        host.presentAsSheet(controller)
    }

    /// Presents any ShipKit view as a sheet. Mac sheets have one size; `compact` and the closure do nothing.
    static func present<Content: View>(compact: Bool, from host: NSViewController, @ViewBuilder content: (_ expand: @escaping @MainActor () -> Void) -> Content) {
        let controller = NSHostingController(rootView: content {}.skSheetSize())
        host.presentAsSheet(controller)
    }
}

/// Keeps the app from being napped or suspended while an answer is on its way.
@MainActor
final class BackgroundActivity {
    private var token: NSObjectProtocol?

    static func begin(_ name: String) -> BackgroundActivity {
        let activity = BackgroundActivity()
        activity.token = ProcessInfo.processInfo.beginActivity(options: [.background, .suddenTerminationDisabled], reason: name)
        return activity
    }

    func end() {
        if let token { ProcessInfo.processInfo.endActivity(token) }
        token = nil
    }
}
#endif
#endif
