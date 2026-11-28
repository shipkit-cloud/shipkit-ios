import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

extension Color {
    static var skBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #elseif os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color.clear
        #endif
    }

    static var skSecondaryBackground: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemBackground)
        #elseif os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color.gray.opacity(0.2)
        #endif
    }

    static var skTertiaryFill: Color {
        #if os(iOS)
        Color(uiColor: .tertiarySystemFill)
        #elseif os(macOS)
        Color(nsColor: .quaternaryLabelColor)
        #else
        Color.gray.opacity(0.2)
        #endif
    }

    static var skGroupedBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #elseif os(macOS)
        Color(nsColor: .underPageBackgroundColor)
        #else
        Color.clear
        #endif
    }
}

extension View {
    /// Inline navigation title where the platform has large titles.
    @ViewBuilder
    func skInlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Keyboard and autofill set up for an email address.
    @ViewBuilder
    func skEmailField() -> some View {
        #if os(iOS)
        keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    @ViewBuilder
    func skNoAutocapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    @ViewBuilder
    func skNumbersKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.numbersAndPunctuation)
        #else
        self
        #endif
    }

    /// Gives a sheet a sensible size on the Mac, where sheets shrink to fit their content.
    @ViewBuilder
    func skSheetSize(width: CGFloat = 480, height: CGFloat = 560) -> some View {
        #if os(macOS)
        frame(minWidth: width, idealWidth: width, minHeight: height, idealHeight: height)
        #else
        self
        #endif
    }

    /// Covers the app with content the user can't dismiss.
    @ViewBuilder
    func skBlockingCover<Cover: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Cover) -> some View {
        #if os(macOS)
        sheet(isPresented: isPresented) {
            content()
                .frame(minWidth: 460, minHeight: 520)
                .interactiveDismissDisabled()
        }
        #else
        fullScreenCover(isPresented: isPresented, content: content)
        #endif
    }

    /// Background of bars pinned to the bottom of a sheet.
    @ViewBuilder
    func skBarBackground() -> some View {
        #if os(tvOS)
        self
        #else
        background(.bar)
        #endif
    }
}
