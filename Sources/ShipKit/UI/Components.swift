import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct PrimaryButtonStyle: ButtonStyle {
    @MainActor var color: Color { ShipKit.theme.primaryColor }

    func makeBody(configuration: Configuration) -> some View {
        #if os(tvOS)
        FocusableBody(configuration: configuration, color: color)
        #else
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: ShipKitThemeReader.cornerRadius, style: .continuous)
                    .fill(color.opacity(configuration.isPressed ? 0.8 : 1))
            )
        #endif
    }

    #if os(tvOS)
    /// A custom button style gets no focus effect from the system, so this draws its own.
    private struct FocusableBody: View {
        let configuration: Configuration
        let color: Color
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.headline)
                .frame(maxWidth: 640)
                .padding(.vertical, 22)
                .foregroundStyle(.white)
                .background(
                    RoundedRectangle(cornerRadius: ShipKitThemeReader.cornerRadius, style: .continuous)
                        .fill(color.opacity(configuration.isPressed ? 0.8 : (isFocused ? 1 : 0.55)))
                )
                .scaleEffect(isFocused ? 1.06 : 1)
                .shadow(color: .black.opacity(isFocused ? 0.35 : 0), radius: 18, y: 10)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
    #endif
}

@MainActor
enum ShipKitThemeReader {
    static var cornerRadius: CGFloat { ShipKit.theme.cornerRadius }
}

struct CountBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .frame(minWidth: 20)
                .background(Capsule().fill(ShipKit.theme.badgeColor))
                .accessibilityLabel(L("inbox.unread.accessibility", count))
        }
    }
}

struct StatusChip: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
}

struct ErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L("common.retry"), action: retry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
}

/// Loads an upload through the authenticated API (plain `AsyncImage` can't send the client headers).
struct AttachmentImage: View {
    let id: String
    @State private var image: PlatformImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(width: 120, height: 160)
        .background(Color.skTertiaryFill)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: id) {
            guard image == nil, let engine = ShipKit.engine else { return }
            do {
                let data = try await engine.attachmentData(id: id)
                image = PlatformImage(data: data)
                failed = image == nil
            } catch {
                failed = true
            }
        }
    }
}

enum Formatting {
    @MainActor static func relative(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        // Server and device clocks can differ by a few seconds; never show a past event as "in 2 sec".
        let now = Date()
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

extension View {
    @ViewBuilder
    func shipKitTint() -> some View {
        tint(ShipKitThemeTint.color)
    }
}

@MainActor
enum ShipKitThemeTint {
    static var color: Color { ShipKit.theme.primaryColor }
}

@MainActor
func errorMessage(_ error: Error) -> String {
    if let error = error as? ShipKitError {
        switch error {
        case .offline: return L("error.offline")
        case .rateLimited: return L("error.rateLimited")
        case .server(_, _, let message?): return message
        default: break
        }
    }
    return L("error.generic")
}

extension View {
    /// Closes the keyboard when the user taps outside a text field or drags the content.
    func shipKitDismissesKeyboard() -> some View {
        #if os(iOS)
        return scrollDismissesKeyboard(.interactively)
            .background(KeyboardDismissInstaller().frame(width: 0, height: 0))
        #else
        return self
        #endif
    }
}

#if os(iOS)
private struct KeyboardDismissInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> InstallerView { InstallerView() }
    func updateUIView(_ uiView: InstallerView, context: Context) {}

    final class InstallerView: UIView, UIGestureRecognizerDelegate {
        private var recognizer: UITapGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
                self.recognizer = nil
            }
            guard let window else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            recognizer = tap
        }

        @objc private func tapped() {
            window?.endEditing(true)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
#endif
