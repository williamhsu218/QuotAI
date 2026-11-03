import Foundation

struct QuotaNotificationEvent: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable { case low, reset }
    let provider: QuotaProvider
    let providerName: String
    let groupID: String
    let groupName: String
    let window: QuotaKind
    let kind: Kind
    let remainingPercent: Int
    let resetsAt: Date?

    var id: String {
        [
            provider.rawValue, groupID, window.rawValue, kind.rawValue,
            String(Int(resetsAt?.timeIntervalSince1970 ?? 0))
        ].joined(separator: ".")
    }
}

/// Only fresh, successful reads advance this state. Startup/cache samples form
/// a baseline; a clock deadline alone is never evidence of a restored balance.
struct QuotaNotificationPolicy {
    private struct State {
        let sampledAt: Date
        let percent: Int
        let resetsAt: Date?
        let lowNotified: Bool
    }
    private var states: [String: State] = [:]
    var threshold: Int = 20

    mutating func reset() { states.removeAll() }

    mutating func evaluate(_ snapshots: [ProviderQuotaSnapshot], at now: Date) -> [QuotaNotificationEvent] {
        var events: [QuotaNotificationEvent] = []
        let threshold = min(50, max(5, threshold))
        for snapshot in snapshots where !snapshot.isHistorical {
            guard snapshot.fetchedAt <= now.addingTimeInterval(60),
                now.timeIntervalSince(snapshot.fetchedAt) <= 600
            else { continue }
            for group in snapshot.groups {
                for quota in group.quotas where !quota.isExpired(at: now) {
                    let key = [snapshot.provider.rawValue, group.id, quota.kind.rawValue].joined(separator: "/")
                    let previous = states[key]
                    if let previous, snapshot.fetchedAt <= previous.sampledAt { continue }
                    let resetConfirmed =
                        previous.map { old in
                            guard let oldReset = old.resetsAt, let newReset = quota.resetsAt else { return false }
                            return oldReset <= snapshot.fetchedAt && newReset > oldReset
                        } ?? false
                    let rearmed = resetConfirmed || quota.remainingPercent >= threshold + 5
                    let wasNotified = rearmed ? false : previous?.lowNotified ?? false
                    let crossedLow =
                        previous.map { $0.percent >= threshold && quota.remainingPercent < threshold } ?? false
                    func event(_ kind: QuotaNotificationEvent.Kind) -> QuotaNotificationEvent {
                        .init(
                            provider: snapshot.provider, providerName: snapshot.providerName,
                            groupID: group.id, groupName: group.name, window: quota.kind, kind: kind,
                            remainingPercent: quota.remainingPercent, resetsAt: quota.resetsAt)
                    }
                    if resetConfirmed { events.append(event(.reset)) }
                    if crossedLow && !wasNotified { events.append(event(.low)) }
                    states[key] = State(
                        sampledAt: snapshot.fetchedAt, percent: quota.remainingPercent,
                        resetsAt: quota.resetsAt, lowNotified: wasNotified || crossedLow)
                }
            }
        }
        return events
    }
}
