import SwiftUI

extension ShipKit {
    /// Full-screen, non-dismissible screen for `required` and `blocked` versions.
    public struct UpdateRequiredView: View {
        private let info: VersionInfo
        @Environment(\.openURL) private var openURL
        static let appStoreFallback = URL(string: "\(ShipKitPlatform.current.storeScheme)://apps.apple.com")!

        public init(_ info: VersionInfo) {
            self.info = info
        }

        private var isBlocked: Bool { info.status == .blocked }

        public var body: some View {
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                VStack(spacing: 18) {
                    Image(systemName: isBlocked ? "exclamationmark.octagon" : "arrow.down.app")
                        .font(.system(size: 64, weight: .regular))
                        .foregroundStyle(ShipKit.theme.primaryColor)
                        .accessibilityHidden(true)
                    Text(info.title ?? L(isBlocked ? "update.blocked.title" : "update.required.title"))
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                    Text(info.message ?? L(isBlocked ? "update.blocked.message" : "update.required.message"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let latest = info.latest ?? info.recommended ?? info.min {
                        Text(L("update.availableVersion", latest))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    PersonalNotes(lines: info.personal)
                    if let floor = info.osFloor, let message = floor.message {
                        Label(message, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 32)
                Spacer(minLength: 24)
                // Never leave a blocked user without a way forward: with no store link, open the App Store app.
                Button(L("update.action.update")) { openURL(info.storeURL ?? Self.appStoreFallback) }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.skBackground.ignoresSafeArea())
            .interactiveDismissDisabled()
        }
    }

    /// Dismissible update reminder for `recommended` versions.
    public struct UpdateReminderSheet: View {
        private let info: VersionInfo
        private let onUpdate: (() -> Void)?
        private let onLater: (() -> Void)?
        private let onSkip: (() -> Void)?
        @Environment(\.openURL) private var openURL
        @Environment(\.dismiss) private var dismiss

        public init(
            _ info: VersionInfo,
            onUpdate: (() -> Void)? = nil,
            onLater: (() -> Void)? = nil,
            onSkip: (() -> Void)? = nil
        ) {
            self.info = info
            self.onUpdate = onUpdate
            self.onLater = onLater
            self.onSkip = onSkip
        }

        private var allowsSkip: Bool { info.reminder?.allowSkip ?? false }

        public var body: some View {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 48))
                        .foregroundStyle(ShipKit.theme.primaryColor)
                        .padding(.top, 32)
                        .accessibilityHidden(true)
                    Text(info.title ?? L("update.recommended.title"))
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    if let target = info.targetVersion {
                        Text(L("update.availableVersion", target))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(info.message ?? L("update.recommended.message"))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    PersonalNotes(lines: info.personal)
                }
                .padding(.horizontal, 28)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    if info.storeURL != nil {
                        Button(L("update.action.update")) {
                            if let url = info.storeURL { openURL(url) }
                            onUpdate?()
                            dismiss()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                    Button(L("update.action.later")) {
                        onLater?()
                        dismiss()
                    }
                    .padding(.vertical, 8)
                    if allowsSkip, let target = info.targetVersion {
                        Button(L("update.action.skip")) {
                            ShipKit.engine?.updateReminderState { ReminderScheduler.recordSkip(target: target, state: &$0) }
                            onSkip?()
                            dismiss()
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .padding(.top, 8)
                .skBarBackground()
            }
            .presentationDetents([.medium, .large])
            .shipKitTint()
        }
    }

    /// Full-screen maintenance screen.
    public struct MaintenanceView: View {
        private let info: VersionInfo
        @State private var retrying = false

        public init(_ info: VersionInfo) {
            self.info = info
        }

        public var body: some View {
            VStack(spacing: 18) {
                Spacer()
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 60))
                    .foregroundStyle(ShipKit.theme.primaryColor)
                    .accessibilityHidden(true)
                Text(info.title ?? L("maintenance.title"))
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text(info.maintenance?.message ?? info.message ?? L("maintenance.message"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let until = info.maintenance?.until {
                    Text(L("maintenance.until", Formatting.dateTime(until)))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    retrying = true
                    Task {
                        await ShipKit.refresh()
                        retrying = false
                    }
                } label: {
                    if retrying {
                        ProgressView().tint(.white)
                    } else {
                        Text(L("common.retry"))
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(retrying)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.skBackground.ignoresSafeArea())
            .interactiveDismissDisabled()
        }
    }

    /// Full-screen, non-dismissible screen shown when no version check has succeeded within
    /// `ShipKitOptions.versionCheckMaxAge`. Goes away as soon as one does.
    public struct CheckRequiredView: View {
        @State private var retrying = false

        public init() {}

        public var body: some View {
            VStack(spacing: 18) {
                Spacer()
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 60))
                    .foregroundStyle(ShipKit.theme.primaryColor)
                    .accessibilityHidden(true)
                Text(L("checkRequired.title"))
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text(L("checkRequired.message"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
                Button {
                    retrying = true
                    Task {
                        await ShipKit.refresh()
                        retrying = false
                    }
                } label: {
                    if retrying {
                        ProgressView().tint(.white)
                    } else {
                        Text(L("common.retry"))
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(retrying)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.skBackground.ignoresSafeArea())
            .interactiveDismissDisabled()
        }
    }

    /// Release notes for the version the user just updated to.
    public struct WhatsNewView: View {
        private let version: String
        private let items: [String]
        private let onContinue: (() -> Void)?
        @Environment(\.dismiss) private var dismiss

        public init(version: String, items: [String], onContinue: (() -> Void)? = nil) {
            self.version = version
            self.items = items
            self.onContinue = onContinue
        }

        public init(_ whatsNew: VersionInfo.WhatsNew, onContinue: (() -> Void)? = nil) {
            self.init(version: whatsNew.version, items: whatsNew.items, onContinue: onContinue)
        }

        public var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(L("whatsNew.title", version))
                        .font(.largeTitle.bold())
                        .padding(.top, 40)
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(ShipKit.theme.primaryColor)
                                .accessibilityHidden(true)
                            Text(item)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
            }
            .safeAreaInset(edge: .bottom) {
                Button(L("common.continue")) {
                    onContinue?()
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(24)
                .skBarBackground()
            }
        }
    }
}

struct PersonalNotes: View {
    let lines: [String]

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Label {
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(ShipKit.theme.primaryColor)
                    }
                    .font(.subheadline)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ShipKit.theme.cornerRadius, style: .continuous)
                    .fill(ShipKit.theme.primaryColor.opacity(0.1))
            )
        }
    }
}
