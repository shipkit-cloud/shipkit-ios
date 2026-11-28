import Foundation

struct Identity: Codable, Equatable, Sendable {
    var userId: String?
    var email: String?
    var name: String?
    var paymentMonthly: Double?
    var attributes: [String: ShipKitValue] = [:]
}

struct AppInfo: Sendable, Equatable {
    var bundleID: String
    var marketingVersion: String
    var build: String

    static var main: AppInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        return AppInfo(
            bundleID: Bundle.main.bundleIdentifier ?? "unknown",
            marketingVersion: info["CFBundleShortVersionString"] as? String ?? "0.0.0",
            build: info["CFBundleVersion"] as? String ?? "0"
        )
    }
}

/// The `Context` object sent with snapshot, feedback and rating requests.
struct RequestContext: Codable, Equatable, Sendable {
    var stableId: String
    var userId: String?
    var email: String?
    var name: String?
    var paymentMonthly: Double?
    var appVersion: String
    var build: String
    var platform: String = ShipKitPlatform.current.rawValue
    var osVersion: String?
    var locale: String?
    var language: String?
    var region: String?
    var device: String?
    var attributes: [String: ShipKitValue]?
    /// Unique per snapshot request, so a signed answer to one request can't be reused for another.
    var nonce: String?
}

enum DeviceInfo {
    static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        #if os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                let model = String(decoding: bytes, as: UTF8.self)
                if !model.isEmpty { return model }
            }
        }
        #endif
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            let bytes = buffer.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        if version.patchVersion > 0 {
            return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        }
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    static var locale: String { Locale.current.identifier }
    static var language: String? { Locale.current.language.languageCode?.identifier }
    static var region: String? { Locale.current.region?.identifier }
}
