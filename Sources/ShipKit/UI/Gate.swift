import SwiftUI

extension View {
    /// Enforces version policy on the view it's applied to (usually the app's root view).
    ///
    /// - `required`, `blocked` and `maintenance` cover the app full-screen and can't be dismissed.
    /// - `checkRequired` (only with `versionCheckMaxAge`) covers the app until a check succeeds.
    /// - `recommended` shows a dismissible reminder, following the server's reminder cadence.
    /// - What's New is shown once on the version it describes.
    /// - Hosts the shake-to-report form when `ShipKit.config.feedback.shakeToReport` is enabled.
    public func shipKitGate() -> some View {
        modifier(ShipKitGateModifier())
    }
}

private enum GateSheet: Identifiable {
    case reminder(VersionInfo)
    case whatsNew(VersionInfo.WhatsNew)
    case feedback
    case push(PushPresentation)

    /// Sheets the user asked for (shake, notification tap), which stay up even when the app gets blocked.
    var isUserInitiated: Bool {
        switch self {
        case .feedback, .push: return true
        case .reminder, .whatsNew: return false
        }
    }

    var id: String {
        switch self {
        case .reminder: return "reminder"
        case .whatsNew: return "whatsNew"
        case .feedback: return "feedback"
        case .push(let presentation): return presentation.id
        }
    }
}

struct ShipKitGateModifier: ViewModifier {
    @ObservedObject private var model = ShipKitModel.shared
    @State private var sheet: GateSheet?
    @State private var ready = false

    private var coverBinding: Binding<Bool> {
        Binding(
            get: { ready && model.versionStatus.isBlocking && sheet == nil },
            set: { _ in }
        )
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .reminder(let info):
                    ShipKit.UpdateReminderSheet(info)
                case .whatsNew(let whatsNew):
                    ShipKit.WhatsNewView(whatsNew)
                case .feedback:
                    FeedbackSheet(category: .bug)
                case .push(let presentation):
                    PushPresentationView(presentation: presentation)
                }
            }
            .fullScreenCover(isPresented: coverBinding) {
                BlockingScreen()
            }
            .task {
                // Give the first frame a moment so presentations don't race the launch transition.
                try? await Task.sleep(for: .milliseconds(400))
                ready = true
                installShakeIfNeeded()
                // A notification the user tapped to open the app goes before reminders.
                presentPendingPush()
                evaluate()
            }
            .onAppear { model.mountedGates += 1 }
            .onDisappear { model.mountedGates -= 1 }
            // Delivered on the next run loop pass so the new value is already stored.
            .onReceive(model.$pendingPush.receive(on: DispatchQueue.main)) { _ in
                presentPendingPush()
            }
            .onChange(of: sheet?.id) { id in
                guard id == nil else { return }
                Task {
                    // Let the dismissal finish; presenting during it gets dropped.
                    try? await Task.sleep(for: .milliseconds(600))
                    presentPendingPush()
                }
            }
            .onReceive(model.$revision.dropFirst()) { _ in
                evaluate()
            }
            .onReceive(model.$configRevision.dropFirst()) { _ in
                installShakeIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: ShakeDetector.notification)) { _ in
                presentShakeFeedback()
            }
    }

    private func evaluate() {
        guard ready, let engine = ShipKit.engine else { return }
        let status = model.versionStatus
        if status.isBlocking {
            if let current = sheet, !current.isUserInitiated { sheet = nil }
            return
        }
        guard sheet == nil, model.pendingPush == nil, !model.presentedGateSheetThisSession else { return }

        let reminderState = engine.reminderState
        if let whatsNew = engine.snapshot?.version?.whatsNew,
           ReminderScheduler.shouldShowWhatsNew(whatsNew, running: engine.runningVersion, state: reminderState) {
            engine.updateReminderState { ReminderScheduler.recordWhatsNewSeen(whatsNew.version, state: &$0) }
            model.presentedGateSheetThisSession = true
            sheet = .whatsNew(whatsNew)
            return
        }

        if case .updateRecommended(let info) = status,
           let target = info.targetVersion,
           ReminderScheduler.shouldShow(target: target, policy: info.reminder, state: reminderState, now: Date()) {
            let now = Date()
            engine.updateReminderState { ReminderScheduler.recordShown(target: target, state: &$0, now: now) }
            model.presentedGateSheetThisSession = true
            sheet = .reminder(info)
        }
    }

    private func presentPendingPush() {
        guard ready, sheet == nil, !model.versionStatus.isBlocking, let pending = model.pendingPush else { return }
        model.pendingPush = nil
        // A sheet can't be stacked on top of one the app presented itself, so go through UIKit then.
        if PushPresenter.hasModal, let host = PushPresenter.topViewController() {
            PushPresenter.present(pending, from: host)
        } else {
            sheet = .push(pending)
        }
    }

    private func installShakeIfNeeded() {
        if ShipKit.config.feedback.shakeToReport {
            ShakeDetector.install()
        }
    }

    private func presentShakeFeedback() {
        guard ShipKit.config.feedback.shakeToReport, sheet == nil, !model.versionStatus.isBlocking else { return }
        ScreenCapture.captureForFeedback()
        sheet = .feedback
    }
}

private struct BlockingScreen: View {
    @ObservedObject private var model = ShipKitModel.shared

    var body: some View {
        switch model.versionStatus {
        case .maintenance(let info):
            ShipKit.MaintenanceView(info)
        case .updateRequired(let info), .blocked(let info):
            ShipKit.UpdateRequiredView(info)
        case .checkRequired:
            ShipKit.CheckRequiredView()
        case .ok, .updateRecommended:
            Color(uiColor: .systemBackground).ignoresSafeArea()
        }
    }
}
