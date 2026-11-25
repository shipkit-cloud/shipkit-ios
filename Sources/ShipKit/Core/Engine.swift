import Foundation
import os

struct Overrides: Codable, Equatable, Sendable {
    var settings: [String: ShipKitValue] = [:]
    var flags: [String: ShipKitValue] = [:]
}

enum FeedbackSubmitResult: Sendable, Equatable {
    case sent(FeedbackThread)
    case queued
}

private struct ExposureKey: Hashable, Sendable {
    var flag: String
    var variant: String
}

private actor RefreshGate {
    private var current: Task<Void, Never>?

    func run(_ work: @escaping @Sendable () async -> Void) async {
        if let current {
            await current.value
            return
        }
        let task = Task { await work() }
        current = task
        await task.value
        current = nil
    }
}

final class Engine: Sendable {
    struct Configuration: Sendable {
        var clientKey: String
        var options: ShipKitOptions
        var appInfo: AppInfo
        var preferences: Preferences
        var directory: URL
        var session: URLSession
        var useKeychain: Bool = true
        var networkEnabled: Bool = true
        var persistent: Bool = true
    }

    private struct State: Sendable {
        var snapshot: ShipKitSnapshot?
        /// Exact bytes of `snapshot` as the server sent them; a "not modified" answer is verified against these.
        var body: Data?
        var meta: SnapshotMeta?
        var lockedSettings: [String: ShipKitValue]?
        var lockedFlags: [String: ShipKitValue]?
        var overrides = Overrides()
        var identity = Identity()
        var reminder = ReminderState()
        var unread = 0
        var exposures: [ExposureKey: Int] = [:]
        var exposedThisSession: Set<ExposureKey> = []
        var lastRefreshAttempt: Date?
        var lastRefreshSuccess: Date?
        var refreshedThisSession = false
        var lastError: String?
    }

    let configuration: Configuration
    let stableID: String
    let api: APIClient
    let store: SnapshotStore
    let queue: FeedbackQueue
    let bundledDefaults: [String: ShipKitValue]
    /// When this install first ran, the reference point for `versionCheckMaxAge` before any check succeeds.
    let firstLaunch: Date
    private let verifier: SignatureVerifier?
    private let state: OSAllocatedUnfairLock<State>
    private let refreshGate = RefreshGate()
    let onChange: @Sendable () -> Void
    let pushState: OSAllocatedUnfairLock<PushState>

    var options: ShipKitOptions { configuration.options }
    var preferences: Preferences { configuration.preferences }

    /// Version simulation, local overrides and the other developer tools. Off in release builds
    /// unless the app opts in, so nothing on the device can switch them on.
    var debugToolsEnabled: Bool { options.debugTools.isEnabled }
    private var signingEnabled: Bool { options.signingKey != nil }

    init(configuration: Configuration, testSnapshot: ShipKitSnapshot? = nil, onChange: @escaping @Sendable () -> Void = {}) {
        self.configuration = configuration
        self.onChange = onChange
        let preferences = configuration.preferences
        stableID = InstallID.resolve(preferences: preferences, useKeychain: configuration.useKeychain)
        store = SnapshotStore(directory: configuration.directory)
        queue = FeedbackQueue(directory: configuration.directory.appendingPathComponent("queue", isDirectory: true))
        api = APIClient(
            baseURL: configuration.options.apiURL,
            clientKey: configuration.clientKey,
            stableID: stableID,
            bundleID: configuration.appInfo.bundleID,
            session: configuration.session
        )
        verifier = configuration.options.signingKey.flatMap { key in
            let verifier = SignatureVerifier(base64PublicKey: key)
            if verifier == nil { ShipKitLog.error("signingKey is not a valid base64 Ed25519 public key; all snapshots will be rejected.") }
            return verifier
        }
        bundledDefaults = Self.loadDefaults(options: configuration.options)
        if configuration.options.signingKey == nil, configuration.networkEnabled {
            ShipKitLog.error("No signingKey set: snapshots are not verified, so version rules can be tampered with in transit. Copy the key from the dashboard.")
        }

        let storedFirstLaunch = configuration.persistent ? preferences.defaults.object(forKey: Preferences.Key.firstLaunch.rawValue) as? Double : nil
        if let storedFirstLaunch {
            firstLaunch = Date(timeIntervalSince1970: storedFirstLaunch)
        } else {
            firstLaunch = Date()
            if configuration.persistent { preferences.set(firstLaunch.timeIntervalSince1970, for: .firstLaunch) }
        }

        var initial = State()
        if let testSnapshot {
            initial.snapshot = testSnapshot
        } else if configuration.persistent {
            // With signing on, the cache has to prove itself again; with a key that can't be parsed nothing can.
            let signing = configuration.options.signingKey != nil
            if signing, verifier == nil {
                store.clear()
            } else if let cached = store.load(verifier: verifier, stableID: stableID) {
                initial.snapshot = cached.snapshot
                initial.body = cached.body
                initial.meta = cached.meta
            }
        }
        if configuration.options.lockFlagsOnLaunch, let snapshot = initial.snapshot {
            initial.lockedSettings = snapshot.settings
            initial.lockedFlags = snapshot.flags
        }
        initial.unread = initial.snapshot?.inbox?.unread ?? 0
        if configuration.persistent {
            if configuration.options.debugTools.isEnabled {
                initial.overrides = preferences.decode(Overrides.self, .overrides) ?? Overrides()
            }
            initial.identity = preferences.decode(Identity.self, .identity) ?? Identity()
            initial.reminder = preferences.decode(ReminderState.self, .reminderState) ?? ReminderState()
        }
        state = OSAllocatedUnfairLock(initialState: initial)
        pushState = OSAllocatedUnfairLock(initialState: PushState(preferences: preferences, persistent: configuration.persistent))
    }

    // MARK: - Values

    func settingValue(_ key: String) -> ShipKitValue? {
        state.withLock { state in
            if let value = state.overrides.settings[key] { return value }
            if let value = (state.lockedSettings ?? state.snapshot?.settings)?[key], !value.isNull { return value }
            return bundledDefaults[key]
        }
    }

    func flagValue(_ key: String) -> ShipKitValue? {
        state.withLock { state in
            if let value = state.overrides.flags[key] { return value }
            if let value = (state.lockedFlags ?? state.snapshot?.flags)?[key], !value.isNull { return value }
            return bundledDefaults[key]
        }
    }

    func isEnabled(_ key: String) -> Bool {
        let value = flagValue(key)
        let enabled: Bool
        switch value {
        case .bool(let flag)?: enabled = flag
        case .string(let string)?: enabled = !["", "false", "off", "0"].contains(string.lowercased())
        case .int(let number)?: enabled = number != 0
        case .double(let number)?: enabled = number != 0
        case .array?, .object?: enabled = true
        case .null?, nil: enabled = false
        }
        if value != nil { recordExposure(flag: key, variant: enabled ? "on" : "off") }
        return enabled
    }

    func variant(_ key: String, default defaultValue: String) -> String {
        guard let value = flagValue(key) else { return defaultValue }
        let variant: String
        switch value {
        case .string(let string): variant = string
        case .bool(let flag): variant = flag ? "on" : "off"
        case .int(let number): variant = String(number)
        case .double(let number): variant = String(number)
        case .null: return defaultValue
        case .array, .object: variant = value.jsonText
        }
        recordExposure(flag: key, variant: variant)
        return variant
    }

    var allSettings: [String: ShipKitValue] {
        state.withLock { state in
            bundledDefaults.merging(state.lockedSettings ?? state.snapshot?.settings ?? [:]) { _, remote in remote }
        }
    }

    var allFlags: [String: ShipKitValue] {
        state.withLock { state in state.lockedFlags ?? state.snapshot?.flags ?? [:] }
    }

    var snapshot: ShipKitSnapshot? { state.withLock { $0.snapshot } }
    var meta: SnapshotMeta? { state.withLock { $0.meta } }
    var lastRefreshSuccess: Date? { state.withLock { $0.lastRefreshSuccess } }
    var lastError: String? { state.withLock { $0.lastError } }
    var identity: Identity { state.withLock { $0.identity } }
    var unread: Int { state.withLock { $0.unread } }

    // MARK: - Version

    var runningVersionString: String {
        guard debugToolsEnabled else { return configuration.appInfo.marketingVersion }
        let defaults = preferences.defaults
        for key in [ShipKitDefaults.simulatedVersionKey, ShipKitDefaults.simulateVersionArgumentKey] {
            if let simulated = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespaces), !simulated.isEmpty {
                return simulated
            }
        }
        return configuration.appInfo.marketingVersion
    }

    var runningVersion: AppVersion {
        AppVersion(runningVersionString, build: configuration.appInfo.build)
    }

    var currentVersionStatus: VersionStatus {
        let (info, meta, attempted) = state.withLock { ($0.snapshot?.version, $0.meta, $0.refreshedThisSession) }
        let fetchedFor = meta.map { AppVersion($0.appVersion, build: $0.build) }
        let status = VersionEvaluator.status(for: info, fetchedFor: fetchedFor, running: runningVersion)
        // Only once this session's own check has had its chance, so a slow launch doesn't flash the screen.
        if !status.isBlocking, attempted, isVersionCheckOverdue(lastChecked: meta?.fetchedAt) {
            return .checkRequired
        }
        return status
    }

    /// `true` when `versionCheckMaxAge` is set and no check has succeeded within it.
    func isVersionCheckOverdue(lastChecked: Date?, now: Date = Date()) -> Bool {
        guard let maxAge = options.versionCheckMaxAge, maxAge > 0, configuration.networkEnabled else { return false }
        let age = now.timeIntervalSince(lastChecked ?? firstLaunch)
        // A last check far in the future means the clock was moved back; that doesn't buy more time.
        return age > maxAge || age < -86_400
    }

    func versionStatus() async -> VersionStatus {
        if !state.withLock({ $0.refreshedThisSession }) {
            await refresh()
        }
        return currentVersionStatus
    }

    // MARK: - Reminder bookkeeping

    var reminderState: ReminderState { state.withLock { $0.reminder } }

    func updateReminderState(_ change: @Sendable (inout ReminderState) -> Void) {
        let updated = state.withLock { state in
            change(&state.reminder)
            return state.reminder
        }
        if configuration.persistent { preferences.encode(updated, .reminderState) }
    }

    func recordLaunch() {
        updateReminderState { ReminderScheduler.recordLaunch(&$0) }
    }

    // MARK: - Context

    func makeContext() -> RequestContext {
        let identity = self.identity
        return RequestContext(
            stableId: stableID,
            userId: identity.userId,
            email: identity.email,
            name: identity.name,
            paymentMonthly: identity.paymentMonthly,
            appVersion: runningVersionString,
            build: configuration.appInfo.build,
            osVersion: DeviceInfo.osVersion,
            locale: DeviceInfo.locale,
            language: DeviceInfo.language,
            region: DeviceInfo.region,
            device: DeviceInfo.modelIdentifier,
            attributes: identity.attributes.isEmpty ? nil : identity.attributes
        )
    }

    func client() throws -> APIClient {
        guard configuration.networkEnabled else { throw ShipKitError.offline }
        return api
    }

    // MARK: - Refresh

    func refreshIfNeeded() async {
        guard case .onForeground(let minInterval) = options.refresh else { return }
        let last = state.withLock { $0.lastRefreshAttempt }
        if let last, Date().timeIntervalSince(last) < minInterval { return }
        await refresh()
    }

    /// Called when a refresh is scheduled but not started yet, so a foreground event arriving
    /// during launch doesn't trigger a second request.
    func noteRefreshScheduled() {
        state.withLock { $0.lastRefreshAttempt = Date() }
    }

    func refresh() async {
        await refreshGate.run { [self] in
            await performRefresh()
        }
    }

    private func performRefresh() async {
        state.withLock { $0.lastRefreshAttempt = Date() }
        do {
            try await fetchSnapshot()
            state.withLock {
                $0.lastRefreshSuccess = Date()
                $0.lastError = nil
            }
        } catch {
            state.withLock { $0.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
        state.withLock { $0.refreshedThisSession = true }
        onChange()
        await flushQueue()
        await sendEvents()
    }

    func fetchSnapshot() async throws {
        let api = try client()
        let context = {
            var context = makeContext()
            context.nonce = UUID().uuidString.lowercased()
            return context
        }()
        let (etag, cachedBody) = state.withLock { state in
            (state.body != nil ? state.meta?.etag : nil, state.body)
        }
        let body = try JSON.encoder.encode(context)
        let (data, response) = try await api.send(
            "POST", "v1/snapshot",
            body: body,
            headers: etag.map { ["If-None-Match": $0] } ?? [:]
        )
        let signature = response.value(forHTTPHeaderField: "X-ShipKit-Signature-V2")

        if response.statusCode == 304 {
            // "Not modified" has to be signed for this request too, or a proxy could freeze the
            // cache by answering 304 to everything.
            guard etag != nil, let cachedBody else { throw ShipKitError.invalidResponse }
            try verify(signature, request: body, response: cachedBody)
            let meta = state.withLock { state -> SnapshotMeta? in
                guard var meta = state.meta else { return nil }
                meta.fetchedAt = Date()
                meta.appVersion = context.appVersion
                meta.build = context.build
                meta.signature = signature
                state.meta = meta
                return meta
            }
            if let meta, configuration.persistent { store.update(meta: meta, request: body) }
            return
        }

        try verify(signature, request: body, response: data)
        let snapshot: ShipKitSnapshot
        do {
            snapshot = try ShipKitSnapshot(jsonData: data)
        } catch {
            throw ShipKitError.invalidResponse
        }
        // The server echoes the version it evaluated. If that isn't the version this app sent, the
        // request was changed on the way and the status in the answer is for some other version.
        if let evaluated = snapshot.version?.current, context.appVersion.count <= 32,
           AppVersion(evaluated).compareVersion(to: AppVersion(context.appVersion)) != .orderedSame {
            throw ShipKitError.invalidResponse
        }
        let meta = SnapshotMeta(
            etag: response.value(forHTTPHeaderField: "ETag"),
            fetchedAt: Date(),
            appVersion: context.appVersion,
            build: context.build,
            signature: signature
        )
        if configuration.persistent { store.save(body: data, request: body, meta: meta) }
        let lock = options.lockFlagsOnLaunch
        state.withLock { state in
            state.snapshot = snapshot
            state.body = data
            state.meta = meta
            state.unread = snapshot.inbox?.unread ?? state.unread
            if lock, state.lockedSettings == nil {
                state.lockedSettings = snapshot.settings
                state.lockedFlags = snapshot.flags
            }
        }
    }

    private func verify(_ signature: String?, request: Data, response: Data) throws {
        guard signingEnabled else { return }
        guard let verifier, verifier.isValid(signature: signature, stableID: stableID, requestBody: request, responseBody: response) else {
            throw ShipKitError.invalidSignature
        }
    }

    // MARK: - Identify

    func identify(_ identity: Identity) async {
        state.withLock { $0.identity = identity }
        if configuration.persistent { preferences.encode(identity, .identity) }
        let body = IdentifyBody(
            userId: identity.userId,
            email: identity.email,
            name: identity.name,
            paymentMonthly: identity.paymentMonthly,
            attributes: identity.attributes.isEmpty ? nil : identity.attributes
        )
        do {
            try await client().perform("POST", "v1/identify", body: body)
        } catch {
            ShipKitLog.error("identify failed: \(error.localizedDescription)")
        }
        await refresh()
    }

    // MARK: - Telemetry

    private func recordExposure(flag: String, variant: String) {
        guard options.telemetry == .on else { return }
        let key = ExposureKey(flag: flag, variant: variant)
        state.withLock { state in
            guard state.exposedThisSession.insert(key).inserted else { return }
            state.exposures[key, default: 0] += 1
        }
    }

    func sendEvents(now: Date = Date()) async {
        guard options.telemetry == .on, let api = try? client() else { return }
        let today = Self.dayString(now)
        let needsPing = preferences.string(.lastPingDay) != today
        let exposures = state.withLock { state -> [ExposureKey: Int] in
            let drained = state.exposures
            state.exposures = [:]
            return drained
        }
        guard needsPing || !exposures.isEmpty else { return }

        let body = EventsBody(
            ping: needsPing ? .init(appVersion: runningVersionString, build: configuration.appInfo.build, osVersion: DeviceInfo.osVersion) : nil,
            exposures: exposures.isEmpty ? nil : exposures
                .map { EventsBody.Exposure(flag: $0.key.flag, variant: $0.key.variant, count: $0.value) }
                .sorted { ($0.flag, $0.variant) < ($1.flag, $1.variant) }
        )
        do {
            try await api.perform("POST", "v1/events", body: body)
            if needsPing { preferences.set(today, for: .lastPingDay) }
        } catch {
            state.withLock { state in
                state.exposures.merge(exposures, uniquingKeysWith: +)
            }
        }
    }

    private static func dayString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - Feedback

    func upload(_ image: ImagePayload) async throws -> String {
        let (data, _) = try await client().send("POST", "v1/uploads", body: image.data, contentType: image.contentType)
        guard let response = try? JSONDecoder().decode(UploadResponse.self, from: data) else {
            throw ShipKitError.invalidResponse
        }
        return response.id
    }

    func submitFeedback(
        category: FeedbackCategory,
        rating: Int?,
        message: String,
        email: String?,
        images: [ImagePayload],
        answers: [FeedbackAnswer]? = nil,
        formRev: String? = nil
    ) async throws -> FeedbackSubmitResult {
        var submission = FeedbackSubmission(
            category: category,
            rating: rating,
            message: message,
            email: email,
            attachments: [],
            context: makeContext(),
            answers: answers,
            formRev: formRev
        )
        var remaining = images
        do {
            while let image = remaining.first {
                submission.attachments.append(try await upload(image))
                remaining.removeFirst()
            }
            let response: ThreadResponse = try await client().json("POST", "v1/feedback", body: submission)
            return .sent(response.thread)
        } catch let error as ShipKitError where error.isTransient && configuration.persistent {
            try queue.enqueue(submission, images: remaining)
            return .queued
        }
    }

    var pendingFeedbackCount: Int { queue.count }

    func flushQueue() async {
        guard configuration.persistent, configuration.networkEnabled else { return }
        for var item in queue.items() {
            do {
                while let image = item.pendingImages.first {
                    guard let data = queue.imageData(image, of: item) else {
                        item.pendingImages.removeFirst()
                        continue
                    }
                    let id = try await upload(ImagePayload(data: data, contentType: image.contentType))
                    item.submission.attachments.append(id)
                    item.pendingImages.removeFirst()
                    try? queue.save(item)
                }
                let _: ThreadResponse = try await api.json("POST", "v1/feedback", body: item.submission)
                queue.remove(item.id)
            } catch let error as ShipKitError where error.isTransient {
                return
            } catch {
                queue.remove(item.id)
            }
        }
    }

    func threads() async throws -> [FeedbackThread] {
        let response: ThreadsResponse = try await client().json("GET", "v1/feedback/threads")
        let unread = response.threads.reduce(0) { $0 + $1.unread }
        state.withLock { $0.unread = unread }
        onChange()
        return response.threads
    }

    func thread(_ id: String) async throws -> (FeedbackThread, [FeedbackMessage]) {
        let response: ThreadDetailResponse = try await client().json("GET", "v1/feedback/threads/\(id)")
        return (response.thread, response.messages)
    }

    func reply(threadID: String, body: String) async throws -> FeedbackMessage {
        let response: MessageResponse = try await client().json("POST", "v1/feedback/threads/\(threadID)/messages", body: BodyText(body: body))
        return response.message
    }

    func refreshUnread() async -> Int {
        if (try? await threads()) == nil, configuration.networkEnabled {
            try? await fetchSnapshot()
            onChange()
        }
        return unread
    }

    func attachmentData(id: String) async throws -> Data {
        let (data, _) = try await client().send("GET", "v1/uploads/\(id)")
        return data
    }

    // MARK: - Ratings

    func myRating(feature: String) async throws -> Int? {
        let response: ScoreResponse = try await client().json(
            "GET", "v1/ratings/mine",
            query: [URLQueryItem(name: "subject", value: "feature"), URLQueryItem(name: "key", value: feature)]
        )
        return response.score
    }

    func rate(feature: String, score: Int) async throws {
        try await client().perform("POST", "v1/ratings", body: RatingSubmission(subject: "feature", key: feature, score: score, context: makeContext()))
    }

    // MARK: - Feature requests

    func requests() async throws -> [FeatureRequest] {
        let response: RequestsResponse = try await client().json("GET", "v1/requests")
        return response.requests
    }

    func createRequest(title: String, description: String, email: String?) async throws -> FeatureRequest {
        let response: RequestResponse = try await client().json(
            "POST", "v1/requests",
            body: NewRequestBody(title: title, description: description, email: email)
        )
        return response.request
    }

    func vote(requestID: String, on: Bool) async throws -> (votes: Int, voted: Bool) {
        let response: VoteResponse = try await client().json(on ? "POST" : "DELETE", "v1/requests/\(requestID)/vote")
        return (response.votes, response.voted)
    }

    func comments(requestID: String) async throws -> [RequestComment] {
        let response: CommentsResponse = try await client().json("GET", "v1/requests/\(requestID)/comments")
        return response.comments
    }

    func comment(requestID: String, body: String) async throws -> RequestComment {
        let response: CommentResponse = try await client().json("POST", "v1/requests/\(requestID)/comments", body: BodyText(body: body))
        return response.comment
    }

    // MARK: - Debug

    var overrides: Overrides { state.withLock { $0.overrides } }

    func setOverride(setting key: String, value: ShipKitValue?) {
        mutateOverrides { $0.settings[key] = value }
    }

    func setOverride(flag key: String, value: ShipKitValue?) {
        mutateOverrides { $0.flags[key] = value }
    }

    func clearOverrides() {
        mutateOverrides { $0 = Overrides() }
    }

    private func mutateOverrides(_ change: @Sendable (inout Overrides) -> Void) {
        guard debugToolsEnabled else { return }
        let updated = state.withLock { state in
            change(&state.overrides)
            return state.overrides
        }
        if configuration.persistent { preferences.encode(updated, .overrides) }
        onChange()
    }

    func setSimulatedVersion(_ version: String?) {
        guard debugToolsEnabled else { return }
        let trimmed = version?.trimmingCharacters(in: .whitespaces)
        preferences.defaults.set((trimmed?.isEmpty ?? true) ? nil : trimmed, forKey: ShipKitDefaults.simulatedVersionKey)
        onChange()
    }

    func clearCache() {
        store.clear()
        state.withLock { state in
            state.snapshot = nil
            state.body = nil
            state.meta = nil
            state.lockedSettings = nil
            state.lockedFlags = nil
        }
        onChange()
    }

    func resetPresentationState() {
        updateReminderState { $0 = ReminderState() }
        onChange()
    }

    // MARK: - Bundled defaults

    private static func loadDefaults(options: ShipKitOptions) -> [String: ShipKitValue] {
        var values: [String: ShipKitValue] = [:]
        if let name = options.defaultsResource {
            values = loadResource(named: name) ?? [:]
            if values.isEmpty { ShipKitLog.error("defaultsResource \(name) not found or empty in the main bundle.") }
        }
        return values.merging(options.defaults) { _, inline in inline }
    }

    private static func loadResource(named name: String) -> [String: ShipKitValue]? {
        let bundle = Bundle.main
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let candidates = ext.isEmpty ? ["json", "plist"] : [ext]
        for candidate in candidates {
            guard let url = bundle.url(forResource: base, withExtension: candidate),
                  let data = try? Data(contentsOf: url) else { continue }
            if candidate == "json" {
                return try? JSONDecoder().decode([String: ShipKitValue].self, from: data)
            }
            if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
               case .object(let object)? = ShipKitValue(any: plist) {
                return object
            }
        }
        return nil
    }
}
