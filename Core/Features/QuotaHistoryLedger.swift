import Foundation

struct QuotaHistoryPoint: Codable, Equatable, Sendable, Identifiable {
    let provider: QuotaProvider
    let providerName: String
    let groupID: String
    let groupName: String
    let window: QuotaKind
    let timestamp: Date
    let remainingPercent: Int
    let resetsAt: Date?

    var id: String {
        [provider.rawValue, groupID, window.rawValue, String(Int(timestamp.timeIntervalSince1970 / 60))]
            .joined(separator: "/")
    }
    var series: String { [providerName, groupName, window.shortLabel].filter { !$0.isEmpty }.joined(separator: " · ") }
}

actor QuotaHistoryLedger {
    private let url: URL
    private let maximumSamples: Int
    private let retention: TimeInterval
    private var points: [QuotaHistoryPoint] = []
    private var loaded = false

    init(url: URL, maximumSamples: Int = 12_000, retention: TimeInterval = 30 * 86_400) {
        self.url = url
        self.maximumSamples = max(1, maximumSamples)
        self.retention = max(60, retention)
    }

    func load(at now: Date = Date()) throws -> [QuotaHistoryPoint] {
        if !loaded {
            points = try PrivateJSONFile.read([QuotaHistoryPoint].self, from: url) ?? []
            loaded = true
        }
        let previous = points
        prune(at: now)
        if points != previous {
            do { try PrivateJSONFile.write(points, to: url) } catch {
                points = previous
                throw error
            }
        }
        return points
    }

    func record(_ snapshots: [ProviderQuotaSnapshot], at now: Date = Date()) throws -> [QuotaHistoryPoint] {
        _ = try load(at: now)
        var indexed = Dictionary(points.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for snapshot in snapshots where !snapshot.isHistorical {
            guard snapshot.fetchedAt <= now.addingTimeInterval(60),
                now.timeIntervalSince(snapshot.fetchedAt) <= 600
            else { continue }
            for group in snapshot.groups {
                for quota in group.quotas where !quota.isExpired(at: now) {
                    let point = QuotaHistoryPoint(
                        provider: snapshot.provider, providerName: snapshot.providerName,
                        groupID: group.id, groupName: group.name, window: quota.kind,
                        timestamp: snapshot.fetchedAt, remainingPercent: quota.remainingPercent,
                        resetsAt: quota.resetsAt)
                    indexed[point.id] = point
                }
            }
        }
        let previous = points
        points = Array(indexed.values)
        prune(at: now)
        if points != previous {
            do { try PrivateJSONFile.write(points, to: url) } catch {
                points = previous
                throw error
            }
        }
        return points
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        points = []
        loaded = true
    }

    private func prune(at now: Date) {
        points = points.filter {
            $0.timestamp >= now.addingTimeInterval(-retention) && $0.timestamp <= now.addingTimeInterval(60)
                && (0...100).contains($0.remainingPercent)
        }.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        if points.count > maximumSamples { points.removeFirst(points.count - maximumSamples) }
    }
}
