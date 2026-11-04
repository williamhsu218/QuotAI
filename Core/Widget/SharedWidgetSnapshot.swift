import Foundation

struct WidgetQuotaRow: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let providerID: String
    let title: String
    let window: String
    let remainingPercent: Int
    let resetsAt: Date?
    let fetchedAt: Date
    let historical: Bool
    var groupID: String? = nil
    var isPrimary: Bool? = nil

    func displayable(at now: Date) -> Bool {
        (0...100).contains(remainingPercent) && fetchedAt <= now.addingTimeInterval(60)
            && (resetsAt.map { $0 > now } ?? true)
    }
    func isStale(at now: Date) -> Bool { historical || now.timeIntervalSince(fetchedAt) > 1_800 }
}

struct SharedWidgetSnapshot: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    let version: Int
    let generatedAt: Date
    let rows: [WidgetQuotaRow]

    static let empty = Self(version: schemaVersion, generatedAt: .distantPast, rows: [])
}

enum WidgetSharedStore {
    static let kind = "QuotAIQuotaWidget"
    static let selectableKind = "QuotAISelectableQuotaWidget"
    static let kinds = [kind, selectableKind]

    static func snapshotURL(in bundle: Bundle = .main) -> URL? {
        guard let group = bundle.object(forInfoDictionaryKey: "QuotAIAppGroup") as? String,
            group.range(of: "^[A-Z0-9]{10}\\.[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
            let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return container.appendingPathComponent("quota-widget-v1.json")
    }

    static func read(from url: URL?) throws -> SharedWidgetSnapshot {
        guard let url else { return .empty }
        let value = try PrivateJSONFile.read(SharedWidgetSnapshot.self, from: url, maximumBytes: 262_144) ?? .empty
        guard value.version == SharedWidgetSnapshot.schemaVersion, value.rows.count <= 64,
            value.rows.allSatisfy({
                (0...100).contains($0.remainingPercent) && $0.title.count <= 200 && $0.id.count <= 300
            })
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    static func write(_ value: SharedWidgetSnapshot, to url: URL?) throws {
        guard let url else { throw CocoaError(.featureUnsupported) }
        try PrivateJSONFile.write(value, to: url)
    }
}

/// Group only each provider's own windows, preserving the user's preferred order.
struct WidgetProviderQuota: Identifiable, Equatable, Sendable {
    let id: String
    let providerID: String
    let name: String
    let detail: String?
    let fiveHour: WidgetQuotaRow?
    let sevenDay: WidgetQuotaRow?
}

extension SharedWidgetSnapshot {
    var providerQuotas: [WidgetProviderQuota] {
        groupedQuotas(rows.filter { $0.isPrimary != false })
    }

    /// All groups are selectable independently of the menu bar's current group.
    var quotaChoices: [WidgetProviderQuota] { groupedQuotas(rows) }

    func quotas(selectionID: String?) -> [WidgetProviderQuota] {
        guard let selectionID else { return providerQuotas }
        return quotaChoices.filter { $0.id == selectionID }
    }

    private func groupedQuotas(_ rows: [WidgetQuotaRow]) -> [WidgetProviderQuota] {
        var order: [String] = []
        var groups: [String: [WidgetQuotaRow]] = [:]
        for row in rows where row.window == "5h" || row.window == "7d" {
            let id = row.groupID.map { "\(row.providerID)/\($0)" } ?? row.providerID
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(row)
        }
        return order.compactMap { id in
            guard let values = groups[id], let first = values.first else { return nil }
            let parts = first.title.components(separatedBy: " · ")
            return WidgetProviderQuota(
                id: id, providerID: first.providerID, name: parts[0],
                detail: parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : nil,
                fiveHour: values.first { $0.window == "5h" }, sevenDay: values.first { $0.window == "7d" })
        }
    }
}
