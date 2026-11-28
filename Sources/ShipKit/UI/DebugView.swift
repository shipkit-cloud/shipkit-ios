#if !os(tvOS)
import SwiftUI

private struct OverrideTarget: Identifiable {
    enum Kind { case setting, flag }
    let kind: Kind
    let key: String
    var id: String { "\(kind)-\(key)" }
}

extension ShipKit {
    /// Developer screen: inspect the snapshot, override settings and flags locally (persisted),
    /// simulate an app version and reset presentation state.
    ///
    /// Follows `ShipKitOptions.debugTools`: in release builds it shows a "disabled" note and none
    /// of its tools work, unless the app opts in.
    public struct DebugView: View {
        @ObservedObject private var model = ShipKitModel.shared
        @State private var simulatedVersion = ""
        @State private var editing: OverrideTarget?
        @State private var refreshing = false

        public init() {}

        public var body: some View {
            let _ = model.revision
            let engine = ShipKit.engine
            Form {
                if let engine, !engine.debugToolsEnabled {
                    Text(L("debug.disabled")).foregroundStyle(.secondary)
                } else if let engine {
                    statusSection(engine)
                    versionSection(engine)
                    valuesSection(engine, kind: .setting)
                    valuesSection(engine, kind: .flag)
                    actionsSection(engine)
                } else {
                    Text(L("debug.notConfigured")).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L("debug.title"))
            .onAppear {
                simulatedVersion = engine?.preferences.defaults.string(forKey: ShipKitDefaults.simulatedVersionKey) ?? ""
            }
            .sheet(item: $editing) { target in
                OverrideEditor(target: target)
                    .skSheetSize(width: 420, height: 320)
            }
        }

        private func statusSection(_ engine: Engine) -> some View {
            Section(L("debug.status")) {
                row(L("debug.versionStatus"), statusText(model.versionStatus))
                row(L("debug.runningVersion"), engine.runningVersion.description)
                row(L("debug.release"), engine.snapshot.map { String($0.release) } ?? "—")
                row("ETag", engine.meta?.etag ?? "—")
                row(L("debug.fetchedAt"), engine.meta.map { Formatting.dateTime($0.fetchedAt) } ?? "—")
                row(L("debug.apiURL"), engine.options.apiURL.absoluteString)
                row(L("debug.signing"), engine.options.signingKey == nil ? L("debug.off") : L("debug.on"))
                row(L("context.installID"), engine.stableID)
                row(L("debug.pendingFeedback"), String(engine.pendingFeedbackCount))
                if let error = engine.lastError {
                    row(L("debug.lastError"), error)
                }
            }
        }

        private func versionSection(_ engine: Engine) -> some View {
            Section {
                HStack {
                    TextField(engine.configuration.appInfo.marketingVersion, text: $simulatedVersion)
                        .skNumbersKeyboard()
                        .autocorrectionDisabled()
                        .skNoAutocapitalization()
                    Button(L("debug.apply")) {
                        engine.setSimulatedVersion(simulatedVersion)
                        Task { await engine.refresh() }
                    }
                    .buttonStyle(.borderless)
                }
                if !simulatedVersion.isEmpty {
                    Button(L("debug.simulate.clear"), role: .destructive) {
                        simulatedVersion = ""
                        engine.setSimulatedVersion(nil)
                        Task { await engine.refresh() }
                    }
                }
            } header: {
                Text(L("debug.simulate"))
            } footer: {
                Text(L("debug.simulate.footer"))
            }
        }

        private func valuesSection(_ engine: Engine, kind: OverrideTarget.Kind) -> some View {
            let overrides = kind == .setting ? engine.overrides.settings : engine.overrides.flags
            let remote = kind == .setting ? engine.allSettings : engine.allFlags
            let keys = Set(remote.keys).union(overrides.keys).sorted()
            return Section(L(kind == .setting ? "debug.settings" : "debug.flags")) {
                if keys.isEmpty {
                    Text(L("debug.empty")).foregroundStyle(.secondary)
                }
                ForEach(keys, id: \.self) { key in
                    Button {
                        editing = OverrideTarget(kind: kind, key: key)
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key).font(.body.monospaced()).foregroundStyle(.primary)
                                if overrides[key] != nil {
                                    Text(L("debug.overridden")).font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Text((overrides[key] ?? remote[key])?.jsonText ?? "null")
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
        }

        private func actionsSection(_ engine: Engine) -> some View {
            Section {
                Button {
                    refreshing = true
                    Task {
                        await engine.refresh()
                        refreshing = false
                    }
                } label: {
                    HStack {
                        Text(L("debug.refresh"))
                        if refreshing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(refreshing)
                Button(L("debug.resetPresentation")) { engine.resetPresentationState() }
                Button(L("debug.clearOverrides"), role: .destructive) { engine.clearOverrides() }
                Button(L("debug.clearCache"), role: .destructive) { engine.clearCache() }
            }
        }

        private func row(_ title: String, _ value: String) -> some View {
            LabeledContent(title) {
                Text(value)
                    .font(.footnote.monospaced())
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }

        private func statusText(_ status: VersionStatus) -> String {
            switch status {
            case .ok: return "ok"
            case .updateRecommended: return "recommended"
            case .updateRequired: return "required"
            case .blocked: return "blocked"
            case .maintenance: return "maintenance"
            case .checkRequired: return "check required"
            }
        }
    }
}

private struct OverrideEditor: View {
    let target: OverrideTarget
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var boolChoice = 0

    private var engine: Engine? { ShipKit.engine }

    private var remoteValue: ShipKitValue? {
        guard let engine else { return nil }
        return target.kind == .setting ? engine.allSettings[target.key] : engine.allFlags[target.key]
    }

    private var currentOverride: ShipKitValue? {
        guard let engine else { return nil }
        return target.kind == .setting ? engine.overrides.settings[target.key] : engine.overrides.flags[target.key]
    }

    private var isBoolean: Bool {
        (currentOverride ?? remoteValue)?.boolValue != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("debug.remoteValue")) {
                    Text(remoteValue?.jsonText ?? "null")
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
                Section {
                    if isBoolean {
                        Picker(L("debug.override"), selection: $boolChoice) {
                            Text(L("debug.remote")).tag(0)
                            Text("true").tag(1)
                            Text("false").tag(2)
                        }
                        .pickerStyle(.segmented)
                    } else {
                        TextField(L("debug.override.placeholder"), text: $text, axis: .vertical)
                            .font(.body.monospaced())
                            .autocorrectionDisabled()
                            .skNoAutocapitalization()
                    }
                } header: {
                    Text(L("debug.override"))
                } footer: {
                    if !isBoolean { Text(L("debug.override.footer")) }
                }
                if currentOverride != nil {
                    Section {
                        Button(L("debug.override.remove"), role: .destructive) {
                            apply(nil)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(target.key)
            .skInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) {
                        if isBoolean {
                            apply(boolChoice == 0 ? nil : .bool(boolChoice == 1))
                        } else {
                            apply(text.isEmpty ? nil : ShipKitValue.parse(text))
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let value = currentOverride {
                    text = value.jsonText
                    if let flag = value.boolValue { boolChoice = flag ? 1 : 2 }
                }
            }
        }
    }

    private func apply(_ value: ShipKitValue?) {
        switch target.kind {
        case .setting: engine?.setOverride(setting: target.key, value: value)
        case .flag: engine?.setOverride(flag: target.key, value: value)
        }
    }
}
#endif
