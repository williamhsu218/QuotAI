import Foundation

public enum LocalSnapshotStore {
    private static let filename = "usage-snapshot.json"

    public static func load(fileManager: FileManager = .default) throws -> UsageSnapshot? {
        let fileURL = try snapshotURL(fileManager: fileManager)
        if !fileManager.fileExists(atPath: fileURL.path) {
            // Migrate legacy snapshot if present
            let supportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
            for legacyName in ["Codexcator", "CodexIndicator"] {
                let legacyURL =
                    supportURL
                    .appendingPathComponent(legacyName, isDirectory: true)
                    .appendingPathComponent(filename, isDirectory: false)
                if let snapshot = try load(from: legacyURL, fileManager: fileManager) {
                    try save(snapshot, fileManager: fileManager)
                    return snapshot
                }
            }
            return nil
        }
        return try load(from: fileURL, fileManager: fileManager)
    }

    /// Reads a snapshot from an explicit location; nil when the file is absent.
    public static func load(from fileURL: URL, fileManager: FileManager = .default) throws -> UsageSnapshot? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UsageSnapshot.self, from: data)
    }

    public static func save(_ snapshot: UsageSnapshot, fileManager: FileManager = .default) throws {
        try save(snapshot, to: snapshotURL(fileManager: fileManager), fileManager: fileManager)
    }

    /// Writes a snapshot atomically to an explicit location.
    public static func save(_ snapshot: UsageSnapshot, to fileURL: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    public static func snapshotURL(fileManager: FileManager = .default) throws -> URL {
        let supportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return
            supportURL
            .appendingPathComponent("QuotAI", isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }
}
