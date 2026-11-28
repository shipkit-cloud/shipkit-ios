import SwiftUI

extension View {
    /// Enforces version policy on the view it's applied to (usually the app's root view).
    ///
    /// - `required`, `blocked` and `maintenance` cover the app full-screen and can't be dismissed.
    /// - `checkRequired` (only with `versionCheckMaxAge`) covers the app until a check succeeds.
    /// - `recommended` shows a dismissible reminder, following the server's reminder cadence.
    /// - What's New is shown once on the version it describes.
    /// - Hosts the shake-to-report form when `ShipKit.config.feedback.shakeToReport` is enabled (iOS),
    ///   and the form opened by `ShipKitFeedbackCommands` (macOS).
    public func shipKitGate() -> some View {
        modifier(ShipKitGateModifier())
    }
}

private enum GateSheet: Identifiable {
    case reminder(VersionInfo)
    case whatsNew(VersionInfo.WhatsNew)
    #if !os(tvOS)
    case feedback
    case push(PushPresentation)
    #endif

    /// Sheets the user asked for (shake, notification tap), which stay up even when the app gets blocked.
    var isUserInitiated: Bool {
        switch self {
        #if !os(tvOS)
        case .feedback, .push: return true
        #endif
        case .reminder, .whatsNew: return false
        }
    }

    var id: String {
        switch self {
        case .reminder: return "reminder"
        case .whatsNew: return "whatsNew"
        #if !os(tvOS)
        case .feedback: return "feedback"
        case .push(let presentation): return presentation.id
        #endif
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
                        .skSheetSize(width: 440, height: 460)
                case .whatsNew(let whatsNew):
                    ShipKit.WhatsNewView(whatsNew)
                        .skSheetSize(width: 460, height: 520)
                #if !os(tvOS)
                case .feedback:
                    FeedbackSheet(category: .bug)
                case .push(let presentation):
                    PushPresentationView(presentation: presentation)
                        .skSheetSize()
                #endif
                }
            }
            .skBlockingCover(isPresented: coverBinding) {
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
            .onDisappear {
                model.mountedGates -= 1
                model.gateSheetVisible = false
            }
            #if !os(tvOS)
            // Delivered on the next run loop pass so the new value is already stored.
            .onReceive(model.$pendingPush.receive(on: DispatchQueue.main)) { _ in
                presentPendingPush()
            }
            .onReceive(NotificationCenter.default.publisher(for: FeedbackTrigger.notification)) { _ in
                presentShakeFeedback()
            }
            #endif
            .onChange(of: sheet?.id) { id in
                model.gateSheetVisible = id != nil
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
    }

    private func evaluate() {
        guard ready, let engine = ShipKit.engine else { return }
        let status = model.versionStatus
        if status.isBlocking {
            if let current = sheet, !current.isUserInitiated { sheet = nil }
            return
        }
        guard sheet == nil, !hasPendingPush, !model.presentedGateSheetThisSession else { return }

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

    private var hasPendingPush: Bool {
        #if os(tvOS)
        false
        #else
        model.pendingPush != nil
        #endif
    }

    private func presentPendingPush() {
        #if !os(tvOS)
        guard ready, sheet == nil, !model.versionStatus.isBlocking, let pending = model.pendingPush else { return }
        model.pendingPush = nil
        // A sheet can't be stacked on top of one the app presented itself, so go through UIKit then.
        if PushPresenter.hasModal, let host = PushPresenter.topViewController() {
            PushPresenter.present(pending, from: host)
        } else {
            sheet = .push(pending)
        }
        #endif
    }

    private func installShakeIfNeeded() {
        #if os(iOS)
        if ShipKit.config.feedback.shakeToReport {
            ShakeDetector.install()
        }
        #endif
    }

    #if !os(tvOS)
    private func presentShakeFeedback() {
        // On the Mac the trigger is the menu command, which the app adds on purpose.
        #if os(iOS)
        guard ShipKit.config.feedback.shakeToReport else { return }
        #endif
        guard sheet == nil, !model.versionStatus.isBlocking else { return }
        ScreenCapture.captureForFeedback()
        sheet = .feedback
    }
    #endif
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
            Color.skBackground.ignoresSafeArea()
        }
    }
}
