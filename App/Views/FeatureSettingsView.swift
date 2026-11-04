import SwiftUI

struct FeatureSettingsView: View {
    let model: QuotAIAppModel
    @AppStorage(DefaultsKey.quotaNotifications) private var notifications = false
    @AppStorage(DefaultsKey.lowQuotaThreshold) private var threshold = 20
    @AppStorage(DefaultsKey.resetNotifications) private var notifyReset = true
    @AppStorage(DefaultsKey.notificationSound) private var sound = false
    @AppStorage(DefaultsKey.quotaHistory) private var history = false
    @AppStorage(DefaultsKey.quotaWidgets) private var widgets = false
    @AppStorage(DefaultsKey.globalShortcut) private var shortcut = false
    @AppStorage(DefaultsKey.claudeAutoRefresh) private var claudeInterval = 0

    var body: some View {
        ScrollView {
            VStack(spacing: AppTheme.Spacing.medium) {
                SettingsSection(title: L10n.text("notifications.title", fallback: "Quota Notifications")) {
                    Toggle(
                        L10n.text("notifications.enable", fallback: "Notify when quota changes"),
                        isOn: Binding(
                            get: { notifications },
                            set: { enabled in Task { await model.setNotificationsEnabled(enabled) } })
                    )
                    .disabled(model.notifications.requesting)
                    if model.notifications.requesting { ProgressView().controlSize(.small) }
                    if notifications {
                        HStack {
                            Text(L10n.text("notifications.threshold", fallback: "Notify below"))
                            Spacer()
                            Picker("", selection: $threshold) {
                                ForEach([5, 10, 20, 30, 50], id: \.self) { Text("\($0)%").tag($0) }
                            }.labelsHidden().frame(width: 110)
                        }
                        Toggle(
                            L10n.text("notifications.reset", fallback: "Notify after a confirmed reset"),
                            isOn: $notifyReset)
                        Toggle(L10n.text("notifications.sound", fallback: "Play a sound"), isOn: $sound)
                        Button(L10n.text("notifications.send_test", fallback: "Send Test Notification")) {
                            Task { await model.notifications.sendTest(sound: sound) }
                        }
                        .disabled(model.previewMode || !model.notifications.authorized || model.notifications.testing)
                        if model.notifications.testRequestAccepted {
                            Text(
                                L10n.text(
                                    "notifications.test_accepted",
                                    fallback:
                                        "Test submitted to macOS. It appears shortly; check Notification Center if banners are disabled."
                                )
                            )
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if model.notifications.deliveryFailed {
                            Text(
                                L10n.text(
                                    "notifications.failed",
                                    fallback:
                                        "A notification could not be delivered. Check system notification settings.")
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if model.notifications.denied {
                        Text(
                            L10n.text(
                                "notifications.permission",
                                fallback: "Allow QuotAI in System Settings → Notifications.")
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(
                        L10n.text(
                            "notifications.detail",
                            fallback:
                                "The first read establishes a baseline. Old results do not trigger notifications; resets require a new successful query."
                        )
                    )
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                SettingsSection(title: L10n.text("widget.title", fallback: "Desktop Widget")) {
                    Toggle(L10n.text("widget.enable", fallback: "Share quota with the desktop widget"), isOn: $widgets)
                        .disabled(!model.previewMode && !model.widget.isAvailable)
                    Text(
                        model.widget.isAvailable || model.previewMode
                            ? L10n.text(
                                "widget.detail",
                                fallback:
                                    "Add QuotAI from Edit Widgets on your desktop. It shows the last query; open QuotAI to refresh. Expired values disappear."
                            )
                            : L10n.text(
                                "widget.requires_signing",
                                fallback:
                                    "Widgets require a signed installation. The current build cannot share widget data."
                            )
                    )
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if model.widget.writeFailed {
                        Text(L10n.text("widget.write_failed", fallback: "Widget data could not be updated."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(L10n.text("widget.repair", fallback: "Repair Widget")) { model.widget.repair() }
                        .disabled(model.previewMode || model.widget.isRecovering)
                    if model.widget.isRecovering { ProgressView().controlSize(.small) }
                    if model.widget.reloadRequested {
                        Text(L10n.text("widget.reload_requested", fallback: "macOS was asked to reload the widget."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.widget.recoveryFailed {
                        Text(
                            L10n.text(
                                "widget.repair_failed",
                                fallback: "Widget recovery could not be confirmed. Try Repair Widget again.")
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                SettingsSection(title: L10n.text("history.title", fallback: "Quota History")) {
                    Toggle(L10n.text("history.record", fallback: "Record new quota samples"), isOn: $history)
                    Text(
                        L10n.text(
                            "history.detail",
                            fallback:
                                "Stored only on this Mac: up to 30 days or 12,000 samples. Pausing keeps existing history. No account IDs or raw responses are recorded."
                        )
                    )
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(L10n.text("history.open", fallback: "View History…")) { model.historyWindow.show() }
                }
                SettingsSection(title: L10n.text("shortcut.title", fallback: "Keyboard Shortcut")) {
                    Toggle(L10n.text("shortcut.enable", fallback: "Open the panel with ⌃⌥Q"), isOn: $shortcut)
                    if shortcut && model.shortcut.conflict {
                        Text(
                            L10n.text("shortcut.conflict", fallback: "This shortcut is already in use by another app.")
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                SettingsSection(title: L10n.text("claude.auto.title", fallback: "Claude Automatic Queries")) {
                    Picker(L10n.text("claude.auto.interval", fallback: "Query interval"), selection: $claudeInterval) {
                        Text(L10n.text("claude.auto.off", fallback: "Manual only")).tag(0)
                        Text(L10n.text("claude.auto.15", fallback: "Every 15 minutes")).tag(900)
                        Text(L10n.text("claude.auto.30", fallback: "Every 30 minutes")).tag(1_800)
                        Text(L10n.text("claude.auto.60", fallback: "Every hour")).tag(3_600)
                    }.disabled(!model.claudeCode.isConnected)
                    Text(
                        L10n.text(
                            "claude.auto.detail",
                            fallback:
                                "Off by default. Optional queries use the same local /usage command and never generate a model response."
                        )
                    )
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(AppTheme.Spacing.large)
        }
        .onChange(of: threshold) { model.resetNotificationBaseline() }
        .onChange(of: notifyReset) { model.preferencesDidChange() }
        .onChange(of: sound) { model.preferencesDidChange() }
        .onChange(of: history) { model.preferencesDidChange() }
        .onChange(of: widgets) { model.preferencesDidChange() }
        .onChange(of: shortcut) { model.preferencesDidChange() }
        .onChange(of: claudeInterval) { model.preferencesDidChange() }
        .task { await model.notifications.refreshAuthorization() }
    }
}
