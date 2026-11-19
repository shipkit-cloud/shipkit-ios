import ObjectiveC
import UIKit

@MainActor
enum ScreenCapture {
    /// Screen captured just before a feedback sheet is presented (button tap or shake).
    private static var pending: UIImage?

    static func captureForFeedback() {
        pending = captureKeyWindow()
    }

    /// The screen the user came from. Called from the form's first `onAppear`: at that point the
    /// push or sheet transition hasn't been committed yet, so the window still shows the previous screen.
    static func screenBeforeFeedback() -> UIImage? {
        defer { pending = nil }
        return pending ?? captureKeyWindow()
    }

    static func captureKeyWindow() -> UIImage? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return nil }
        let target: UIView = window.rootViewController?.view ?? window
        let renderer = UIGraphicsImageRenderer(bounds: target.bounds)
        return renderer.image { _ in
            target.drawHierarchy(in: target.bounds, afterScreenUpdates: false)
        }
    }
}

/// Posts `notification` when the device is shaken. Installed only when shake-to-report is enabled.
@MainActor
enum ShakeDetector {
    static let notification = Notification.Name("ShipKitDeviceShaken")
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true

        // Motion events bubble up the responder chain to the window, so hooking UIWindow catches
        // shakes without the SDK having to become first responder and steal it from text fields.
        let windowClass: AnyClass = UIWindow.self
        let selector = #selector(UIResponder.motionEnded(_:with:))
        let name = notification
        guard let method = class_getInstanceMethod(windowClass, selector) else { return }

        typealias MotionFunction = @convention(c) (AnyObject, Selector, UIEvent.EventSubtype, UIEvent?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: MotionFunction.self)
        let replacement: @convention(block) (AnyObject, UIEvent.EventSubtype, UIEvent?) -> Void = { object, motion, event in
            if motion == .motionShake {
                NotificationCenter.default.post(name: name, object: nil)
            }
            original(object, selector, motion, event)
        }
        let implementation = imp_implementationWithBlock(replacement)
        if !class_addMethod(windowClass, selector, implementation, method_getTypeEncoding(method)) {
            method_setImplementation(method, implementation)
        }
    }
}
