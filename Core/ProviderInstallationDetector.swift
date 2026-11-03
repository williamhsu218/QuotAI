import Foundation

/// Checks installed programs without launching them or reading account data.
/// Configuration, usage caches and application-support directories are never
/// evidence of an installation: they can remain after the program is removed.
public enum ProviderInstallationDetector {
    /// - Parameter cache: Reuses earlier directory scans. Nil scans every time.
    public static func antigravity(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationDirectories: [URL]? = nil,
        fileManager: FileManager = .default,
        cache: ApplicationInstallationCache? = nil
    ) -> Bool {
        containsApplication(
            bundleIdentifier: "com.google.antigravity",
            directories: applicationDirectories ?? defaultApplicationDirectories(homeDirectory),
            fileManager: fileManager,
            cache: cache
        )
    }

    private static func defaultApplicationDirectories(_ homeDirectory: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         homeDirectory.appendingPathComponent("Applications", isDirectory: true)]
    }

    private static func containsApplication(
        bundleIdentifier: String,
        directories: [URL],
        fileManager: FileManager,
        cache: ApplicationInstallationCache?
    ) -> Bool {
        directories.contains { directory in
            guard directory.isFileURL else { return false }
            let scan = {
                firstApplication(bundleIdentifier: bundleIdentifier, in: directory, fileManager: fileManager)
            }
            guard let cache else { return scan() != nil }
            return cache.application(
                bundleIdentifier: bundleIdentifier,
                in: directory,
                fileManager: fileManager,
                verify: { isApplication($0, bundleIdentifier: bundleIdentifier, fileManager: fileManager) },
                scan: scan
            ) != nil
        }
    }

    private static func firstApplication(
        bundleIdentifier: String,
        in directory: URL,
        fileManager: FileManager
    ) -> URL? {
        guard let applications = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return applications.first {
            isApplication($0, bundleIdentifier: bundleIdentifier, fileManager: fileManager)
        }
    }

    private static func isApplication(
        _ application: URL,
        bundleIdentifier: String,
        fileManager: FileManager
    ) -> Bool {
        guard application.pathExtension.lowercased() == "app",
              (try? application.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
              let data = try? Data(contentsOf: application.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty,
              !executable.contains("/"),
              executable != ".", executable != ".." else { return false }
        return isExecutableFile(
            application.appendingPathComponent("Contents/MacOS", isDirectory: true)
                .appendingPathComponent(executable),
            fileManager: fileManager
        )
    }

    private static func isExecutableFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard url.isFileURL else { return false }
        let resolved = url.resolvingSymlinksInPath()
        guard let attributes = try? fileManager.attributesOfItem(atPath: resolved.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        return fileManager.isExecutableFile(atPath: resolved.path)
    }
}

/// Remembers the result of scanning an application directory, so frequent
/// installation checks (menu bar clock, panel opening, each refresh) do not
/// read every bundle's Info.plist on the main thread.
///
/// A directory is scanned again when its modification date changes (a bundle
/// was added, removed, renamed or replaced) or the previous scan is older
/// than `maximumAge`. The age limit also covers a bundle that was still being
/// copied during the previous scan. A remembered match is verified on every
/// call, so a removed or broken installation is noticed immediately.
public final class ApplicationInstallationCache: @unchecked Sendable {
    public static let shared = ApplicationInstallationCache()

    private struct Entry {
        let directoryModificationDate: Date?
        let scannedAt: Date
        let match: URL?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let maximumAge: TimeInterval
    private let now: @Sendable () -> Date

    public init(maximumAge: TimeInterval = 300, now: @escaping @Sendable () -> Date = { Date() }) {
        self.maximumAge = maximumAge
        self.now = now
    }

    func application(
        bundleIdentifier: String,
        in directory: URL,
        fileManager: FileManager,
        verify: (URL) -> Bool,
        scan: () -> URL?
    ) -> URL? {
        let key = bundleIdentifier + "\u{0}" + directory.standardizedFileURL.path
        let modificationDate = (try? fileManager.attributesOfItem(atPath: directory.path))?[.modificationDate] as? Date
        let current = now()
        let cached = lock.withLock { entries[key] }
        if let cached, cached.directoryModificationDate == modificationDate {
            let age = current.timeIntervalSince(cached.scannedAt)
            if age >= 0, age < maximumAge {
                guard let match = cached.match else { return nil }
                if verify(match) { return match }
            }
        }
        let match = scan()
        lock.withLock {
            entries[key] = Entry(directoryModificationDate: modificationDate, scannedAt: current, match: match)
        }
        return match
    }
}
