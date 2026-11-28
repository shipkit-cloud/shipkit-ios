#if os(macOS)
import SwiftUI

/// Adds "Send Feedback…" to the Help menu. It opens the feedback form over the front window,
/// with a picture of that window ready to attach.
///
/// The Mac counterpart of shake-to-report. Requires `.shipKitGate()` on the window's root view.
///
/// ```swift
/// WindowGroup { RootView().shipKitGate() }
///     .commands { ShipKitFeedbackCommands() }
/// ```
public struct ShipKitFeedbackCommands: Commands {
    private let title: String?
    private let shortcut: KeyboardShortcut?

    /// - Parameters:
    ///   - title: Menu item title. Defaults to the localized "Send Feedback…".
    ///   - shortcut: Keyboard shortcut. None by default.
    public init(title: String? = nil, shortcut: KeyboardShortcut? = nil) {
        self.title = title
        self.shortcut = shortcut
    }

    public var body: some Commands {
        CommandGroup(before: .help) {
            Button(title ?? (L("entry.feedback") + "…")) {
                ShipKit.presentFeedback()
            }
            .keyboardShortcut(shortcut)
        }
    }
}

extension ShipKit {
    /// Opens the feedback form over the front window, as the menu command does.
    /// Requires `.shipKitGate()` on the window's root view.
    @MainActor
    public static func presentFeedback() {
        NotificationCenter.default.post(name: FeedbackTrigger.notification, object: nil)
    }
}
#endif
