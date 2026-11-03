import Foundation
import Observation
import UserNotifications

@MainActor @Observable
final class QuotaNotificationController: NSObject, UNUserNotificationCenterDelegate {
    private(set) var authorized = false
    private(set) var requesting = false
    private(set) var denied = false
    private(set) var deliveryFailed = false
    private(set) var testing = false
    private(set) var testRequestAccepted = false
    @ObservationIgnored private let center: UNUserNotificationCenter?
    @ObservationIgnored private let onOpen: @MainActor (QuotaProvider) -> Void
    @ObservationIgnored private var authorizationRevision = 0

    init(preview: Bool, onOpen: @escaping @MainActor (QuotaProvider) -> Void) {
        center = preview ? nil : .current()
        self.onOpen = onOpen
        super.init()
        center?.delegate = self
    }

    func refreshAuthorization() async {
        guard let center else { return }
        authorizationRevision &+= 1
        let revision = authorizationRevision
        let settings = await center.notificationSettings()
        guard revision == authorizationRevision else { return }
        denied = settings.authorizationStatus == .denied
        authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    func requestPermission() async -> Bool {
        requesting = true
        defer { requesting = false }
        authorizationRevision &+= 1
        if let center {
            do { authorized = try await center.requestAuthorization(options: [.alert, .sound]) } catch {
                authorized = false
            }
            await refreshAuthorization()
        } else {
            authorized = true
        }
        return authorized
    }

    func deliver(_ events: [QuotaNotificationEvent], sound: Bool) async {
        guard authorized, let center else { return }
        let grouped = Dictionary(grouping: events) { "\($0.provider.rawValue)/\($0.kind.rawValue)" }
        for key in grouped.keys.sorted() {
            guard let values = grouped[key], let first = values.first else { continue }
            let content = UNMutableNotificationContent()
            content.title =
                first.providerName + " · "
                + (first.kind == .low
                    ? L10n.text("notifications.low_title", fallback: "Quota running low")
                    : L10n.text("notifications.reset_title", fallback: "Quota reset confirmed"))
            content.body = values.map {
                [$0.groupName, $0.window.shortLabel, "\($0.remainingPercent)%"].filter { !$0.isEmpty }.joined(
                    separator: " · ")
            }.joined(separator: "\n")
            content.userInfo = ["provider": first.provider.rawValue]
            if sound { content.sound = .default }
            do {
                try await center.add(UNNotificationRequest(identifier: first.id, content: content, trigger: nil))
                deliveryFailed = false
            } catch { deliveryFailed = true }
        }
    }

    /// Exercise the installed app's real authorization and notification delivery
    /// without advancing quota baselines or manufacturing quota events.
    func sendTest(sound: Bool) async {
        guard authorized, !testing, let center else { return }
        testing = true
        testRequestAccepted = false
        defer { testing = false }
        let content = UNMutableNotificationContent()
        content.title = L10n.text("notifications.test_title", fallback: "QuotAI notification test")
        content.body = L10n.text(
            "notifications.test_body",
            fallback: "Notifications are working. This is a test, not a quota change. Click to open QuotAI.")
        content.userInfo = ["provider": QuotaProvider.codex.rawValue]
        if sound { content.sound = .default }
        do {
            try await center.add(
                UNNotificationRequest(
                    identifier: "quotai.notification-test", content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)))
            testRequestAccepted = true
            deliveryFailed = false
        } catch { deliveryFailed = true }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let raw = response.notification.request.content.userInfo["provider"] as? String
        if let raw, let provider = QuotaProvider(rawValue: raw) {
            Task { @MainActor [weak self] in self?.onOpen(provider) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
