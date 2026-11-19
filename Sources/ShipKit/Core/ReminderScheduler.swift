import Foundation

/// Persisted bookkeeping for update reminders and What's New.
struct ReminderState: Codable, Equatable, Sendable {
    var launchesSinceShown: Int = 0
    var lastShown: Date?
    var lastShownVersion: String?
    var shownCount: [String: Int] = [:]
    var skippedVersion: String?
    var whatsNewSeen: [String] = []
}

enum ReminderScheduler {
    /// Decides whether the update reminder should be shown on this launch.
    ///
    /// The first reminder for a target version is shown right away. After that, both `everyLaunches`
    /// and `everyDays` must be satisfied when both are set, so the stricter rule wins.
    static func shouldShow(target: String, policy: VersionInfo.Reminder?, state: ReminderState, now: Date) -> Bool {
        let key = normalized(target)
        if let skipped = state.skippedVersion, normalized(skipped) == key, policy?.allowSkip != false {
            return false
        }

        let shown = state.shownCount[key] ?? 0
        if let max = policy?.maxPerVersion, max > 0, shown >= max { return false }
        guard shown > 0, let lastShown = state.lastShown else { return true }

        if let launches = policy?.everyLaunches, launches > 0, state.launchesSinceShown < launches {
            return false
        }
        if let days = policy?.everyDays, days > 0, now.timeIntervalSince(lastShown) < Double(days) * 86_400 {
            return false
        }
        if policy?.everyLaunches == nil, policy?.everyDays == nil {
            return state.launchesSinceShown >= 1
        }
        return true
    }

    static func recordLaunch(_ state: inout ReminderState) {
        state.launchesSinceShown += 1
    }

    static func recordShown(target: String, state: inout ReminderState, now: Date) {
        let key = normalized(target)
        state.shownCount[key, default: 0] += 1
        state.lastShown = now
        state.lastShownVersion = key
        state.launchesSinceShown = 0
    }

    static func recordSkip(target: String, state: inout ReminderState) {
        state.skippedVersion = normalized(target)
    }

    /// What's New is shown once, on the version it describes.
    static func shouldShowWhatsNew(_ whatsNew: VersionInfo.WhatsNew?, running: AppVersion, state: ReminderState) -> Bool {
        guard let whatsNew, !whatsNew.items.isEmpty else { return false }
        guard running.compareVersion(to: AppVersion(whatsNew.version)) == .orderedSame else { return false }
        return !state.whatsNewSeen.contains(normalized(whatsNew.version))
    }

    static func recordWhatsNewSeen(_ version: String, state: inout ReminderState) {
        let key = normalized(version)
        if !state.whatsNewSeen.contains(key) { state.whatsNewSeen.append(key) }
    }

    private static func normalized(_ version: String) -> String {
        var components = AppVersion(version).components
        while components.count > 1, components.last == 0 { components.removeLast() }
        return components.map(String.init).joined(separator: ".")
    }
}
