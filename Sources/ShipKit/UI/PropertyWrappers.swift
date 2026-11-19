import SwiftUI

/// Reads a feature flag and re-renders the view when a new snapshot arrives.
///
///     @ShipKitFlag("new_onboarding") var newOnboarding
@MainActor
@propertyWrapper
public struct ShipKitFlag: DynamicProperty {
    @ObservedObject private var model = ShipKitModel.shared
    private let key: String

    public init(_ key: String) {
        self.key = key
    }

    public var wrappedValue: Bool {
        _ = model.revision
        return ShipKit.isEnabled(key)
    }
}

/// Reads a feature flag variant and re-renders the view when a new snapshot arrives.
///
///     @ShipKitVariant("paywall_layout", default: "A") var layout
@MainActor
@propertyWrapper
public struct ShipKitVariant: DynamicProperty {
    @ObservedObject private var model = ShipKitModel.shared
    private let key: String
    private let defaultValue: String

    public init(_ key: String, default defaultValue: String = "control") {
        self.key = key
        self.defaultValue = defaultValue
    }

    public var wrappedValue: String {
        _ = model.revision
        return ShipKit.variant(key, default: defaultValue)
    }
}

/// Reads a remote setting and re-renders the view when a new snapshot arrives.
///
///     @ShipKitSetting("max_upload_mb", default: 25) var maxUpload
@MainActor
@propertyWrapper
public struct ShipKitSetting<Value: Decodable>: DynamicProperty {
    @ObservedObject private var model = ShipKitModel.shared
    private let key: String
    private let defaultValue: Value

    public init(_ key: String, default defaultValue: Value) {
        self.key = key
        self.defaultValue = defaultValue
    }

    public var wrappedValue: Value {
        _ = model.revision
        return ShipKit.setting(key, default: defaultValue)
    }
}
