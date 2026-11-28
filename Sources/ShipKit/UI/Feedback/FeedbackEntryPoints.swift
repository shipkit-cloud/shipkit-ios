#if !os(tvOS)
import SwiftUI

extension ShipKit {
    /// A navigation row that pushes the feedback form. Place it inside a `NavigationStack`.
    public struct FeedbackLink: View {
        private let title: String?
        private let systemImage: String
        private let category: FeedbackCategory

        public init(_ title: String? = nil, systemImage: String = "envelope", category: FeedbackCategory = .bug) {
            self.title = title
            self.systemImage = systemImage
            self.category = category
        }

        public var body: some View {
            NavigationLink {
                ShipKit.FeedbackView(category: category)
            } label: {
                Label(title ?? L("entry.feedback"), systemImage: systemImage)
            }
        }
    }

    /// A button that presents the feedback form in a sheet.
    public struct FeedbackButton<Label: View>: View {
        private let category: FeedbackCategory
        private let label: Label
        @State private var presented = false

        public init(category: FeedbackCategory = .bug, @ViewBuilder label: () -> Label) {
            self.category = category
            self.label = label()
        }

        public var body: some View {
            Button {
                ScreenCapture.captureForFeedback()
                presented = true
            } label: {
                label
            }
            .sheet(isPresented: $presented) {
                FeedbackSheet(category: category)
            }
        }
    }

    /// A navigation row that pushes the feedback inbox, with an unread badge.
    public struct FeedbackInboxLink: View {
        private let title: String?
        private let systemImage: String
        @ObservedObject private var model = ShipKitModel.shared

        public init(_ title: String? = nil, systemImage: String = "tray") {
            self.title = title
            self.systemImage = systemImage
        }

        public var body: some View {
            NavigationLink {
                ShipKit.FeedbackInboxView()
            } label: {
                HStack {
                    SwiftUI.Label(title ?? L("entry.inbox"), systemImage: systemImage)
                    Spacer()
                    CountBadge(count: model.unreadCount)
                }
            }
            .task { _ = await ShipKit.engine?.refreshUnread() }
        }
    }

    /// A navigation row that pushes the feature request board.
    public struct RequestBoardLink: View {
        private let title: String?
        private let systemImage: String

        public init(_ title: String? = nil, systemImage: String = "lightbulb") {
            self.title = title
            self.systemImage = systemImage
        }

        public var body: some View {
            NavigationLink {
                ShipKit.RequestBoardView()
            } label: {
                Label(title ?? L("entry.requests"), systemImage: systemImage)
            }
        }
    }
}

extension ShipKit.FeedbackButton where Label == SwiftUI.Label<Text, Image> {
    public init(_ title: String? = nil, systemImage: String = "envelope", category: FeedbackCategory = .bug) {
        self.init(category: category) {
            SwiftUI.Label(title ?? L("entry.feedback"), systemImage: systemImage)
        }
    }
}

struct FeedbackSheet: View {
    let category: FeedbackCategory
    var prompt: String?
    var ask: ShipKitAsk?
    var onSubmitted: (@MainActor () -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ShipKit.FeedbackView(category: category, prompt: prompt, ask: ask, onSubmitted: onSubmitted)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L("common.cancel")) { dismiss() }
                    }
                }
        }
        .skSheetSize()
    }
}
#endif
