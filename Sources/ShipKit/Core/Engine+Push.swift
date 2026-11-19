import Foundation

struct PushState: Sendable {
    var token: String?
    var asks: Bool
    /// token|authorization|environment of the last successful registration this session.
    var lastSent: String?

    init(preferences: Preferences, persistent: Bool) {
        guard persistent else {
            asks = true
            return
        }
        token = preferences.string(.pushToken)
        asks = preferences.defaults.object(forKey: Preferences.Key.pushAsks.rawValue) as? Bool ?? true
    }
}

extension Engine {
    var pushToken: String? { pushState.withLock { $0.token } }
    var pushAsksEnabled: Bool { pushState.withLock { $0.asks } }

    /// Stores the token and reports whether it differs from the one already known.
    @discardableResult
    func storePushToken(_ token: String) -> Bool {
        let changed = pushState.withLock { state -> Bool in
            guard state.token != token else { return false }
            state.token = token
            state.lastSent = nil
            return true
        }
        if changed, configuration.persistent { preferences.set(token, for: .pushToken) }
        return changed
    }

    private func updateAsks(_ asks: Bool) {
        let changed = pushState.withLock { state -> Bool in
            defer { state.asks = asks }
            return state.asks != asks
        }
        if configuration.persistent { preferences.set(asks, for: .pushAsks) }
        if changed { onChange() }
    }

    /// Registers the stored token. Skips the request when the same token, status and environment
    /// were already sent this session.
    func postPushToken(authorization: String, environment: ShipKitPushEnvironment) async {
        guard let token = pushToken else { return }
        let key = "\(token)|\(authorization)|\(environment.rawValue)"
        guard pushState.withLock({ $0.lastSent != key }) else { return }
        let body = PushTokenBody(
            token: token,
            environment: environment.rawValue,
            authorization: authorization,
            context: makeContext()
        )
        do {
            let response: PushAsksResponse = try await client().json("POST", "v1/push/token", body: body)
            pushState.withLock { $0.lastSent = key }
            if let asks = response.asks { updateAsks(asks) }
        } catch {
            ShipKitLog.error("Push token registration failed: \(error.localizedDescription)")
        }
    }

    func deletePushToken() async throws {
        let token = pushState.withLock { state -> String? in
            defer {
                state.token = nil
                state.lastSent = nil
            }
            return state.token
        }
        if configuration.persistent { preferences.set(nil, for: .pushToken) }
        guard let token else { return }
        try await client().perform("DELETE", "v1/push/token", body: PushTokenDeleteBody(token: token))
    }

    func setPushAsks(_ enabled: Bool) async throws {
        let response: PushAsksResponse = try await client().json("PUT", "v1/push/preferences", body: PushAsksBody(asks: enabled))
        updateAsks(response.asks ?? enabled)
    }

    func refreshPushPreferences() async throws {
        let response: PushAsksResponse = try await client().json("GET", "v1/push/preferences")
        if let asks = response.asks { updateAsks(asks) }
    }

    func pushDelivery(_ id: String) async throws -> PushPayload {
        let (data, _) = try await client().send("GET", "v1/push/deliveries/\(id)")
        do {
            return try PushPayload(deliveryResponse: data)
        } catch {
            throw ShipKitError.invalidResponse
        }
    }

    func markPushOpened(_ id: String, action: String) async {
        do {
            try await client().perform("POST", "v1/push/deliveries/\(id)/opened", body: PushOpenedBody(action: action))
        } catch {
            ShipKitLog.error("Could not record push \(action): \(error.localizedDescription)")
        }
    }

    /// Sends an answer. With `queueOnFailure`, answers that fail for transient reasons (offline,
    /// server busy) are kept and retried on the next launch.
    func answerPush(_ id: String, answer: PushAnswer, queueOnFailure: Bool = false) async throws {
        let body = PushAnswerBody(value: answer.value, text: answer.text, context: makeContext())
        do {
            try await client().perform("POST", "v1/push/deliveries/\(id)/answer", body: body)
        } catch let error as ShipKitError where error.isTransient && queueOnFailure && configuration.persistent {
            enqueuePushAnswer(PendingPushAnswer(deliveryID: id, value: answer.value, text: answer.text))
        }
    }

    var pendingPushAnswers: [PendingPushAnswer] {
        preferences.decode([PendingPushAnswer].self, .pushPendingAnswers) ?? []
    }

    private func enqueuePushAnswer(_ answer: PendingPushAnswer) {
        var pending = pendingPushAnswers.filter { $0.deliveryID != answer.deliveryID }
        pending.append(answer)
        preferences.encode(Array(pending.suffix(20)), .pushPendingAnswers)
    }

    func flushPushAnswers() async {
        guard configuration.persistent, configuration.networkEnabled else { return }
        var pending = pendingPushAnswers
        guard !pending.isEmpty else { return }
        while let item = pending.first {
            let body = PushAnswerBody(value: item.value, text: item.text, context: makeContext())
            do {
                try await api.perform("POST", "v1/push/deliveries/\(item.deliveryID)/answer", body: body)
            } catch let error as ShipKitError where error.isTransient {
                break
            } catch {
                // Rejected by the server (expired delivery etc.); drop it.
            }
            pending.removeFirst()
        }
        preferences.encode(pending, .pushPendingAnswers)
    }
}
