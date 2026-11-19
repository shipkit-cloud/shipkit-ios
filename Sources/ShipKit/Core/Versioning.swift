import Foundation

/// A marketing version plus optional build number, e.g. `2.4.0 (311)` or `2.4.0-beta.2+311`.
public struct AppVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let components: [Int]
    public let prerelease: [String]
    public let build: String?

    public init(_ version: String, build: String? = nil) {
        var core = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if core.hasPrefix("v") || core.hasPrefix("V") { core.removeFirst() }

        var parsedBuild = build?.trimmingCharacters(in: .whitespaces)
        if let plus = core.firstIndex(of: "+") {
            if parsedBuild == nil || parsedBuild?.isEmpty == true {
                parsedBuild = String(core[core.index(after: plus)...])
            }
            core = String(core[..<plus])
        }

        var pre: [String] = []
        if let dash = core.firstIndex(of: "-") {
            pre = core[core.index(after: dash)...].split(separator: ".").map(String.init)
            core = String(core[..<dash])
        }

        components = core.split(separator: ".").map { part in
            Int(part.prefix { $0.isNumber }) ?? 0
        }
        prerelease = pre
        self.build = (parsedBuild?.isEmpty ?? true) ? nil : parsedBuild
    }

    public var description: String {
        var text = components.map(String.init).joined(separator: ".")
        if !prerelease.isEmpty { text += "-" + prerelease.joined(separator: ".") }
        if let build { text += " (\(build))" }
        return text
    }

    /// Compares marketing versions only (`2.4` == `2.4.0`, `2.4.0-beta` < `2.4.0`).
    public func compareVersion(to other: AppVersion) -> ComparisonResult {
        let count = Swift.max(components.count, other.components.count)
        for index in 0..<count {
            let lhs = index < components.count ? components[index] : 0
            let rhs = index < other.components.count ? other.components[index] : 0
            if lhs != rhs { return lhs < rhs ? .orderedAscending : .orderedDescending }
        }
        return Self.comparePrerelease(prerelease, other.prerelease)
    }

    /// Compares version, then build when both sides carry one.
    public func compare(to other: AppVersion) -> ComparisonResult {
        let versionOrder = compareVersion(to: other)
        guard versionOrder == .orderedSame else { return versionOrder }
        guard let build, let otherBuild = other.build else { return .orderedSame }
        return build.compare(otherBuild, options: .numeric)
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.compare(to: rhs) == .orderedAscending
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.compare(to: rhs) == .orderedSame
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
        hasher.combine(prerelease)
    }

    private static func comparePrerelease(_ lhs: [String], _ rhs: [String]) -> ComparisonResult {
        switch (lhs.isEmpty, rhs.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false): break
        }
        for (left, right) in zip(lhs, rhs) where left != right {
            switch (Int(left), Int(right)) {
            case let (l?, r?): return l < r ? .orderedAscending : .orderedDescending
            case (.some, nil): return .orderedAscending
            case (nil, .some): return .orderedDescending
            case (nil, nil): return left < right ? .orderedAscending : .orderedDescending
            }
        }
        if lhs.count == rhs.count { return .orderedSame }
        return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
    }
}

enum VersionEvaluator {
    /// Turns the server's version payload into a status for the app version that is running now.
    ///
    /// The server computes `status` for the version that was sent in the request. If the app was
    /// updated (or a simulated version changed) since the cached snapshot was fetched, the decision
    /// is re-derived locally from `min`/`recommended` so an old `required` doesn't outlive the update.
    static func status(for info: VersionInfo?, fetchedFor: AppVersion?, running: AppVersion) -> VersionStatus {
        guard let info else { return .ok }
        if info.status == .maintenance { return .maintenance(info) }

        if let fetchedFor, !sameRelease(fetchedFor, running) {
            if let min = info.min, running < AppVersion(min) { return .updateRequired(info) }
            if let recommended = info.recommended, running < AppVersion(recommended) { return .updateRecommended(info) }
            return .ok
        }

        switch info.status {
        case .ok: return .ok
        case .recommended: return .updateRecommended(info)
        case .required: return .updateRequired(info)
        case .blocked: return .blocked(info)
        case .maintenance: return .maintenance(info)
        }
    }

    private static func sameRelease(_ lhs: AppVersion, _ rhs: AppVersion) -> Bool {
        lhs.compareVersion(to: rhs) == .orderedSame && lhs.build == rhs.build
    }
}
