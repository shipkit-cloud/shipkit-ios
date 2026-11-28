import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The platform this build of the SDK runs on, as the API names it.
enum ShipKitPlatform: String, Sendable {
    case ios
    case macos
    case tvos

    /// Mac Catalyst apps are iOS apps to the App Store, so they report `ios`.
    static var current: ShipKitPlatform {
        #if os(tvOS)
        .tvos
        #elseif os(macOS)
        .macos
        #else
        .ios
        #endif
    }

    var displayName: String {
        switch self {
        case .ios: "iOS"
        case .macos: "macOS"
        case .tvos: "tvOS"
        }
    }

    /// Opens the App Store app directly when no store URL is configured.
    var storeScheme: String {
        switch self {
        case .macos: "macappstore"
        case .ios, .tvos: "itms-apps"
        }
    }
}

/// The few calls that differ between UIKit and AppKit.
@MainActor
enum PlatformApp {
    /// Posted when the app comes back to the front.
    static var foregroundNotification: Notification.Name {
        #if canImport(UIKit)
        UIApplication.willEnterForegroundNotification
        #else
        NSApplication.didBecomeActiveNotification
        #endif
    }

    static var isActive: Bool {
        #if canImport(UIKit)
        UIApplication.shared.applicationState == .active
        #else
        NSApplication.shared.isActive
        #endif
    }

    static func open(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    static func registerForRemoteNotifications() {
        #if canImport(UIKit)
        UIApplication.shared.registerForRemoteNotifications()
        #else
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }
}

#if canImport(UIKit)
typealias PlatformImage = UIImage
typealias PlatformViewController = UIViewController
#else
typealias PlatformImage = NSImage
typealias PlatformViewController = NSViewController

extension NSImage {
    var bestCGImage: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Size in pixels of the largest representation, falling back to the size in points.
    var pixelSize: CGSize {
        if let cgImage = bestCGImage {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }
        return size
    }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cgImage = bestCGImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }

    /// Redraws the image at `pixelSize` and paints `blackBoxes` (normalized, top-left origin) over it.
    func redrawn(pixelSize: CGSize, blackBoxes: [CGRect] = []) -> NSImage {
        let width = Int(pixelSize.width.rounded())
        let height = Int(pixelSize.height.rounded())
        guard width > 0, height > 0, let source = bestCGImage,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return self }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .high
        context.draw(source, in: full)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for box in blackBoxes {
            // Core Graphics counts rows from the bottom.
            context.fill(CGRect(
                x: box.minX * full.width,
                y: (1 - box.maxY) * full.height,
                width: box.width * full.width,
                height: box.height * full.height
            ))
        }
        guard let result = context.makeImage() else { return self }
        return NSImage(cgImage: result, size: size)
    }
}
#endif
