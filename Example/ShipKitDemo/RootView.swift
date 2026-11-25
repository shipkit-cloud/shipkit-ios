import ShipKit
import SwiftUI
import UserNotifications

struct RootView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.indigo)
    }
}

struct HomeView: View {
    @ShipKitSetting("promo_banner", default: "") private var promoBanner
    @ShipKitSetting("max_upload_mb", default: 25) private var maxUploadMB
    @ShipKitFlag("new_onboarding") private var newOnboarding
    @ShipKitVariant("paywall_layout", default: "A") private var paywallLayout
    @State private var showingDebug = false
    @State private var refreshing = false
    @State private var unread = 0

    var body: some View {
        NavigationStack {
            List {
                if !promoBanner.isEmpty {
                    Section {
                        Label(promoBanner, systemImage: "megaphone.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .listRowBackground(Color.indigo)
                    }
                }

                Section("Remote settings") {
                    LabeledContent("promo_banner", value: promoBanner.isEmpty ? "—" : promoBanner)
                    LabeledContent("max_upload_mb", value: "\(maxUploadMB) MB")
                }

                Section("Feature flags") {
                    LabeledContent("new_onboarding") {
                        Text(newOnboarding ? "On" : "Off")
                            .foregroundStyle(newOnboarding ? .green : .secondary)
                    }
                    LabeledContent("paywall_layout", value: paywallLayout)
                    PaywallPreview(layout: paywallLayout)
                }

                if newOnboarding {
                    Section("New onboarding") {
                        Label("You're seeing the new onboarding experience.", systemImage: "sparkles")
                    }
                }

                Section {
                    Button {
                        refreshing = true
                        Task {
                            await ShipKit.refresh()
                            unread = await ShipKit.unreadCount()
                            refreshing = false
                        }
                    } label: {
                        HStack {
                            Text("Refresh configuration")
                            Spacer()
                            if refreshing { ProgressView() }
                        }
                    }
                    LabeledContent("Unread replies", value: "\(unread)")
                } footer: {
                    Text("Shake the device to report a problem.")
                }
            }
            .navigationTitle("ShipKit Demo")
            #if DEBUG
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Debug") { showingDebug = true }
                }
            }
            #endif
            .sheet(isPresented: $showingDebug) {
                NavigationStack {
                    ShipKit.DebugView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingDebug = false }
                            }
                        }
                }
            }
            .refreshable { await ShipKit.refresh() }
            .task { unread = await ShipKit.unreadCount() }
        }
    }
}

private struct PaywallPreview: View {
    let layout: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: layout == "B" ? "rectangle.split.2x1.fill" : "rectangle.fill")
                .font(.title2)
                .foregroundStyle(layout == "B" ? .orange : .indigo)
            VStack(alignment: .leading) {
                Text(layout == "B" ? "Side-by-side plans" : "Single plan card")
                    .font(.subheadline.weight(.semibold))
                Text("Paywall layout \(layout)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SettingsView: View {
    @State private var showingDebug = false
    @State private var notificationStatus = "—"

    var body: some View {
        NavigationStack {
            Form {
                Section("Support") {
                    ShipKit.FeedbackLink()
                    ShipKit.FeedbackInboxLink()
                    ShipKit.RequestBoardLink()
                }

                Section {
                    ShipKit.RatingRow(feature: "new_editor", title: "How do you like the new editor?")
                } header: {
                    Text("New editor")
                }

                Section {
                    LabeledContent("Permission", value: notificationStatus)
                    Button("Enable notifications") {
                        Task {
                            await ShipKit.requestPushPermission()
                            await loadNotificationStatus()
                        }
                    }
                    .disabled(notificationStatus == "Allowed")
                } header: {
                    Text("Notifications")
                }

                ShipKitPushAsksToggle()
                ShipKitPushUpdatesToggle()

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Install ID") {
                        Text(ShipKit.installID ?? "—")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                #if DEBUG
                Section {
                    Button("Open Debug Menu") { showingDebug = true }
                }
                #endif
            }
            .navigationTitle("Settings")
            .task { await loadNotificationStatus() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                Task { await loadNotificationStatus() }
            }
            .sheet(isPresented: $showingDebug) {
                NavigationStack {
                    ShipKit.DebugView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingDebug = false }
                            }
                        }
                }
            }
        }
    }

    private func loadNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: notificationStatus = "Allowed"
        case .denied: notificationStatus = "Denied"
        case .notDetermined: notificationStatus = "Not asked yet"
        @unknown default: notificationStatus = "—"
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
