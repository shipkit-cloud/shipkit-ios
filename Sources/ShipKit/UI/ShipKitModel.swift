import SwiftUI

/// Publishes snapshot changes to SwiftUI.
@MainActor
final class ShipKitModel: ObservableObject {
    static let shared = ShipKitModel()

    @Published private(set) var revision = 0
    @Published private(set) var versionStatus: VersionStatus = .ok
    @Published private(set) var unreadCount = 0
    @Published private(set) var configRevision = 0
    @Published private(set) var pushAsksEnabled = true
    @Published private(set) var pushUpdatesEnabled = true
    /// A push presentation waiting for `.shipKitGate()` (or the UIKit fallback) to show it.
    #if !os(tvOS)
    @Published var pendingPush: PushPresentation?
    #endif
    /// Number of `.shipKitGate()` modifiers currently on screen.
    var mountedGates = 0
    /// A gate sheet (reminder, What's New, push, shake feedback) is on screen. In-app asks wait.
    var gateSheetVisible = false

    /// Only one gate sheet (reminder or What's New) is shown per launch.
    var presentedGateSheetThisSession = false

    func reload() {
        let engine = ShipKit.engine
        let status = engine?.currentVersionStatus ?? .ok
        if status != versionStatus { versionStatus = status }
        let unread = engine?.unread ?? 0
        if unread != unreadCount { unreadCount = unread }
        let asks = engine?.pushAsksEnabled ?? true
        if asks != pushAsksEnabled { pushAsksEnabled = asks }
        let updates = engine?.pushUpdatesEnabled ?? true
        if updates != pushUpdatesEnabled { pushUpdatesEnabled = updates }
        revision &+= 1
    }

    func resetSession() {
        presentedGateSheetThisSession = false
    }

    func configDidChange() {
        configRevision &+= 1
    }
}

public struct ShipKitTheme: Sendable {
    public var primaryColor: Color = .accentColor
    public var badgeColor: Color = .red
    public var developerBubbleColor: Color = Color.skSecondaryBackground
    public var userBubbleTextColor: Color = .white
    public var cornerRadius: CGFloat = 14

    public init() {}
}

public struct ShipKitConfig: Sendable {
    public struct Feedback: Sendable {
        /// Opens the feedback form when the device is shaken. Requires `.shipKitGate()` on the root view.
        /// iOS only: on macOS add `ShipKitFeedbackCommands` to the scene instead.
        public var shakeToReport = false
        /// Allows attaching screenshots (photo library and current screen). When off, a custom form's
        /// screenshot field is hidden too.
        public var attachScreenshot = true
        /// Shows the optional star rating in the standard feedback form. A form designed in the
        /// dashboard decides this itself.
        public var showsRating = true
        /// Shows the optional email field in the standard feedback form. A form designed in the
        /// dashboard decides this itself.
        public var asksForEmail = true
        public var maxAttachments = 3

        public init() {}
    }

    public var feedback = Feedback()
    /// Replaces any built-in string, keyed by its localization key (see `Localizable.strings`).
    public var strings: [String: String] = [:]

    public init() {}
}
