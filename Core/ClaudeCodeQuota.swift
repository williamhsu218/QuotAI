import CryptoKit
import CoreFoundation
import Darwin
import Foundation

/// A local receipt of Claude Code's documented status-line rate-limit fields.
/// Neither its receipt time nor its session fingerprint identifies an account
/// or a server sampling time.
public struct ClaudeCodeQuotaReport: Codable, Equatable, Sendable, Identifiable {
    public static let displayLifetime: TimeInterval = 30 * 60
    public let kind: QuotaKind
    public let usedPercentage: Double
    public let resetsAt: Date
    public let firstObservedAt: Date
    public var id: QuotaKind { kind }

    public init(kind: QuotaKind, usedPercentage: Double, resetsAt: Date, firstObservedAt: Date) {
        self.kind = kind
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
        self.firstObservedAt = firstObservedAt
    }

    public var quota: QuotaWindow {
        let remaining = usedPercentage.isFinite && (0...100).contains(usedPercentage) ? Int((100 - usedPercentage).rounded(.down)) : 0
        return QuotaWindow(kind: kind, remainingPercent: remaining, resetsAt: resetsAt)
    }

    public func isExpired(at now: Date) -> Bool { resetsAt <= now }

    public func isDisplayable(at now: Date) -> Bool {
        let age = now.timeIntervalSince(firstObservedAt)
        return usedPercentage.isFinite && (0...100).contains(usedPercentage)
            && age.isFinite && age >= 0 && age < Self.displayLifetime && !isExpired(at: now)
    }
}

public enum ClaudeCodeQuotaSource: String, Codable, Sendable {
    case statusLine, usageQuery
}

public struct ClaudeCodeQuotaSnapshot: Codable, Equatable, Sendable {
    public let fiveHour: ClaudeCodeQuotaReport?
    public let sevenDay: ClaudeCodeQuotaReport?
    public let sessionFingerprint: String
    public let lastCallbackAt: Date
    public let source: ClaudeCodeQuotaSource

    public init(fiveHour: ClaudeCodeQuotaReport?, sevenDay: ClaudeCodeQuotaReport?, sessionFingerprint: String, lastCallbackAt: Date, source: ClaudeCodeQuotaSource = .statusLine) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sessionFingerprint = sessionFingerprint
        self.lastCallbackAt = lastCallbackAt
        self.source = source
    }

    private enum CodingKeys: String, CodingKey { case fiveHour, sevenDay, sessionFingerprint, lastCallbackAt, source }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try values.decodeIfPresent(ClaudeCodeQuotaReport.self, forKey: .fiveHour)
        sevenDay = try values.decodeIfPresent(ClaudeCodeQuotaReport.self, forKey: .sevenDay)
        sessionFingerprint = try values.decode(String.self, forKey: .sessionFingerprint)
        lastCallbackAt = try values.decode(Date.self, forKey: .lastCallbackAt)
        source = try values.decodeIfPresent(ClaudeCodeQuotaSource.self, forKey: .source) ?? .statusLine
    }

    public func isHistorical(at now: Date) -> Bool {
        now < lastCallbackAt || now.timeIntervalSince(lastCallbackAt) >= ClaudeCodeQuotaReport.displayLifetime
    }

    public var orderedReports: [ClaudeCodeQuotaReport] { [fiveHour, sevenDay].compactMap { $0 } }

    public func displayableQuotas(at now: Date) -> [QuotaWindow] {
        guard lastCallbackAt <= now else { return [] }
        return orderedReports.filter {
            source == .usageQuery
                ? $0.usedPercentage.isFinite && (0...100).contains($0.usedPercentage) && $0.resetsAt > now
                : $0.isDisplayable(at: now)
        }.map(\.quota)
    }

    public func nextDisplayDeadline(after now: Date) -> Date? {
        guard lastCallbackAt <= now else { return nil }
        if source == .usageQuery {
            return ([lastCallbackAt.addingTimeInterval(ClaudeCodeQuotaReport.displayLifetime)]
                + orderedReports.map(\.resetsAt)).filter { $0 > now }.min()
        }
        return orderedReports.filter { $0.isDisplayable(at: now) }.map {
            min($0.resetsAt, $0.firstObservedAt.addingTimeInterval(ClaudeCodeQuotaReport.displayLifetime))
        }.min()
    }

    public func menuBarLines(for mode: MenuBarQuotaDisplayMode, now: Date? = nil) -> [String] {
        let reference = now ?? Date()
        let valid = displayableQuotas(at: reference)
        let lines = mode.selectedKinds.compactMap { kind -> String? in
            guard orderedReports.contains(where: { $0.kind == kind }) || mode != .both else { return nil }
            guard let quota = valid.first(where: { $0.kind == kind }) else { return "\(kind.shortLabel) --" }
            return "\(kind.shortLabel) ~\(quota.remainingPercent)%"
        }
        return lines.isEmpty ? ["--"] : lines
    }
}

public struct ClaudeCodeUsageSession: Identifiable, Equatable, Sendable {
    public let id: String
    public var label: String { String(id.prefix(8)) }
    public init(id: String) { self.id = id }
}

/// Nil selects Auto; an explicit fingerprint stays pinned. Automatic reports
/// are local callback observations, never proof of an account or live process.
public struct ClaudeCodeSessionSelection: Equatable, Sendable {
    public enum AutoPolicy: Equatable, Sendable {
        /// Follow the session with the latest locally received callback that
        /// still contains at least one displayable official window.
        case latestDisplayableReport
        /// Require one unambiguous displayable session; otherwise wait for an
        /// explicit choice. This does not establish OS process liveness.
        case onlyDisplayableSession
    }

    public var selectedSessionID: String?
    public init(selectedSessionID: String? = nil) { self.selectedSessionID = selectedSessionID }
    public func resolve(in snapshots: [ClaudeCodeQuotaSnapshot], at now: Date = Date(), autoPolicy: AutoPolicy = .latestDisplayableReport) -> ClaudeCodeQuotaSnapshot? {
        Self.resolve(in: snapshots, selectedSessionID: selectedSessionID, autoPolicy: autoPolicy, at: now)
    }

    /// Pure, opt-in resolver for an automatic selection mode. Nil means Auto;
    /// a nonnil fingerprint means a manually pinned session, including its
    /// unavailable/stale state. No windows are combined across sessions, no
    /// timestamps are changed, and a callback identifies a session, not an
    /// account or a currently running process.
    public static func resolve(
        in snapshots: [ClaudeCodeQuotaSnapshot],
        selectedSessionID: String?,
        autoPolicy: AutoPolicy = .latestDisplayableReport,
        at now: Date
    ) -> ClaudeCodeQuotaSnapshot? {
        if let selectedSessionID {
            return snapshots.first { $0.sessionFingerprint == selectedSessionID }
        }
        let candidates = automaticCandidates(in: snapshots, at: now)
        switch autoPolicy {
        case .latestDisplayableReport:
            // Preserve a waiting/hidden state when no report remains usable.
            // The fallback cannot contribute percentages: it failed the same
            // displayableQuotas check used by the UI and menu bar.
            return candidates.first ?? sortedByCallback(snapshots.filter {
                $0.lastCallbackAt.timeIntervalSince1970.isFinite && $0.lastCallbackAt <= now
            }).first
        case .onlyDisplayableSession: return candidates.count == 1 ? candidates.first : nil
        }
    }

    public static func automaticCandidates(in snapshots: [ClaudeCodeQuotaSnapshot], at now: Date) -> [ClaudeCodeQuotaSnapshot] {
        sortedByCallback(snapshots.filter { !$0.displayableQuotas(at: now).isEmpty })
    }

    private static func sortedByCallback(_ snapshots: [ClaudeCodeQuotaSnapshot]) -> [ClaudeCodeQuotaSnapshot] {
        snapshots.sorted {
            if $0.lastCallbackAt != $1.lastCallbackAt { return $0.lastCallbackAt > $1.lastCallbackAt }
            return $0.sessionFingerprint < $1.sessionFingerprint
        }
    }
}

public enum ClaudeCodeRateLimitParser {
    public static let inputLimit = 1_048_576

    /// Missing/invalid windows are absent in this callback, never filled from
    /// the previous report. Identical windows retain their own first receipt.
    public static func parse(_ data: Data, previous: ClaudeCodeQuotaSnapshot?, sessionSalt: String, configurationFingerprint: String, now: Date) -> ClaudeCodeQuotaSnapshot? {
        guard data.count <= inputLimit,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = root["session_id"] as? String,
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sessionID.utf8.count <= 1_024,
              !sessionSalt.isEmpty, !configurationFingerprint.isEmpty,
              now.timeIntervalSince1970.isFinite else { return nil }
        let fingerprint = sessionFingerprint(sessionID: sessionID, salt: sessionSalt, configurationFingerprint: configurationFingerprint)
        let old = previous?.sessionFingerprint == fingerprint ? previous : nil
        let limits = root["rate_limits"] as? [String: Any]
        return ClaudeCodeQuotaSnapshot(
            fiveHour: report(limits?["five_hour"], kind: .fiveHour, previous: old?.fiveHour, now: now),
            sevenDay: report(limits?["seven_day"], kind: .sevenDay, previous: old?.sevenDay, now: now),
            sessionFingerprint: fingerprint, lastCallbackAt: now
        )
    }

    public static func sessionFingerprint(sessionID: String, salt: String, configurationFingerprint: String) -> String {
        hash(Data((salt + "\u{0}" + configurationFingerprint + "\u{0}" + sessionID).utf8))
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue
        return number.isFinite ? number : nil
    }

    private static func report(_ value: Any?, kind: QuotaKind, previous: ClaudeCodeQuotaReport?, now: Date) -> ClaudeCodeQuotaReport? {
        guard let window = value as? [String: Any],
              let used = number(window["used_percentage"]), (0...100).contains(used),
              let seconds = number(window["resets_at"]),
              seconds.rounded(.towardZero) == seconds else { return nil }
        let reset = Date(timeIntervalSince1970: seconds)
        let remaining = reset.timeIntervalSince(now)
        let maximum: TimeInterval = kind == .fiveHour ? 5 * 3_600 + 300 : 7 * 86_400 + 300
        guard remaining > 0, remaining <= maximum else { return nil }
        let firstObserved = previous.flatMap {
            $0.usedPercentage == used && $0.resetsAt == reset ? $0.firstObservedAt : nil
        } ?? now
        return ClaudeCodeQuotaReport(kind: kind, usedPercentage: used, resetsAt: reset, firstObservedAt: firstObserved)
    }
}

/// Only these Codable types reach disk. Raw status-line JSON is never saved.
public struct ClaudeCodeReportArchive: Codable, Equatable, Sendable {
    public static let maximumSessions = 8
    public static let retention: TimeInterval = 24 * 3_600
    public let version: Int
    public let configurationFingerprint: String
    public private(set) var snapshots: [ClaudeCodeQuotaSnapshot]
    /// Deduplication receipts survive missing-window callbacks, without being
    /// filled into the current snapshots shown by the app.
    public private(set) var receiptHistory: [ClaudeCodeQuotaSnapshot]

    public init(configurationFingerprint: String, snapshots: [ClaudeCodeQuotaSnapshot] = []) {
        version = 2
        self.configurationFingerprint = configurationFingerprint
        self.snapshots = Array(snapshots.prefix(Self.maximumSessions))
        self.receiptHistory = self.snapshots
    }

    public mutating func record(_ snapshot: ClaudeCodeQuotaSnapshot, now: Date) {
        let old = previousReceipt(for: snapshot.sessionFingerprint)
        snapshots.removeAll {
            $0.sessionFingerprint == snapshot.sessionFingerprint
                || now.timeIntervalSince($0.lastCallbackAt) >= Self.retention
                || $0.lastCallbackAt > now
        }
        // Preserve a stable ordering: the store pins its selection separately.
        snapshots.append(snapshot)
        if snapshots.count > Self.maximumSessions { snapshots.removeFirst(snapshots.count - Self.maximumSessions) }
        receiptHistory.removeAll { $0.sessionFingerprint == snapshot.sessionFingerprint }
        receiptHistory.append(ClaudeCodeQuotaSnapshot(fiveHour: snapshot.fiveHour ?? old?.fiveHour,
            sevenDay: snapshot.sevenDay ?? old?.sevenDay, sessionFingerprint: snapshot.sessionFingerprint, lastCallbackAt: snapshot.lastCallbackAt))
        let retainedIDs = Set(snapshots.map(\.sessionFingerprint))
        receiptHistory.removeAll { !retainedIDs.contains($0.sessionFingerprint) }
    }

    public func previousReceipt(for sessionFingerprint: String) -> ClaudeCodeQuotaSnapshot? {
        receiptHistory.first { $0.sessionFingerprint == sessionFingerprint }
    }

    public func retained(at now: Date) -> [ClaudeCodeQuotaSnapshot] {
        snapshots.filter {
            let age = now.timeIntervalSince($0.lastCallbackAt)
            return age >= 0 && age < Self.retention
        }
    }
}

public enum ClaudeCodeReportRepository {
    public static var reportsURL: URL {
        ClaudeCodeStatusLineConfiguration.supportDirectory.appendingPathComponent("claude-code-observations-v2.json")
    }
    public static let fileLimit = 65_536

    public static func read(configurationFingerprint: String, reportsURL: URL = reportsURL) throws -> ClaudeCodeReportArchive {
        guard FileManager.default.fileExists(atPath: reportsURL.path) else {
            return ClaudeCodeReportArchive(configurationFingerprint: configurationFingerprint)
        }
        let archive = try JSONDecoder().decode(ClaudeCodeReportArchive.self, from: ClaudeCodePrivateFile.read(reportsURL, limit: fileLimit))
        guard archive.version == 2,
              archive.snapshots.count <= ClaudeCodeReportArchive.maximumSessions,
              archive.receiptHistory.count <= ClaudeCodeReportArchive.maximumSessions,
              Set(archive.snapshots.map(\.sessionFingerprint)).count == archive.snapshots.count,
              Set(archive.receiptHistory.map(\.sessionFingerprint)).count == archive.receiptHistory.count,
              archive.snapshots.allSatisfy({ valid($0) }), archive.receiptHistory.allSatisfy({ valid($0) }) else { throw ClaudeCodeConfigurationError.invalidReports }
        guard archive.configurationFingerprint == configurationFingerprint else {
            return ClaudeCodeReportArchive(configurationFingerprint: configurationFingerprint)
        }
        return archive
    }

    @discardableResult
    public static func record(input: Data, state: ClaudeCodeBridgeState, reportsURL: URL = reportsURL, now: Date = Date()) throws -> Bool {
        guard state.enabled, input.count <= ClaudeCodeRateLimitParser.inputLimit else { return false }
        return try ClaudeCodePrivateFile.withLock(at: reportsURL.appendingPathExtension("lock")) {
            var archive = try read(configurationFingerprint: state.configurationFingerprint, reportsURL: reportsURL)
            // Parsing twice is bounded and avoids retaining the raw session ID.
            guard let candidate = ClaudeCodeRateLimitParser.parse(input, previous: nil, sessionSalt: state.sessionSalt, configurationFingerprint: state.configurationFingerprint, now: now) else { return false }
            let previous = archive.previousReceipt(for: candidate.sessionFingerprint)
            guard let snapshot = ClaudeCodeRateLimitParser.parse(input, previous: previous, sessionSalt: state.sessionSalt, configurationFingerprint: state.configurationFingerprint, now: now) else { return false }
            if let current = archive.snapshots.first(where: { $0.sessionFingerprint == candidate.sessionFingerprint }),
               current.orderedReports == snapshot.orderedReports,
               now.timeIntervalSince(current.lastCallbackAt) >= 0,
               now.timeIntervalSince(current.lastCallbackAt) < 60 { return false }
            archive.record(snapshot, now: now)
            let data = try JSONEncoder().encode(archive)
            guard data.count <= fileLimit else { throw ClaudeCodeConfigurationError.invalidReports }
            try ClaudeCodePrivateFile.atomicWrite(data, to: reportsURL, permissions: 0o600)
            return true
        }
    }

    public static func clear(reportsURL: URL = reportsURL) throws {
        try ClaudeCodePrivateFile.withLock(at: reportsURL.appendingPathExtension("lock")) {
            try ClaudeCodePrivateFile.rejectSymlink(reportsURL)
            if FileManager.default.fileExists(atPath: reportsURL.path) { try FileManager.default.removeItem(at: reportsURL) }
        }
    }

    private static func valid(_ snapshot: ClaudeCodeQuotaSnapshot) -> Bool {
        guard snapshot.sessionFingerprint.count == 64,
              snapshot.sessionFingerprint.allSatisfy({ $0.isHexDigit }),
              snapshot.lastCallbackAt.timeIntervalSince1970.isFinite else { return false }
        return snapshot.orderedReports.allSatisfy {
            $0.usedPercentage.isFinite && (0...100).contains($0.usedPercentage)
                && $0.resetsAt.timeIntervalSince1970.isFinite && $0.firstObservedAt.timeIntervalSince1970.isFinite
                && ($0.kind == .fiveHour ? snapshot.fiveHour?.kind == .fiveHour : snapshot.sevenDay?.kind == .sevenDay)
        } && snapshot.fiveHour?.kind != .sevenDay && snapshot.sevenDay?.kind != .fiveHour
    }
}
