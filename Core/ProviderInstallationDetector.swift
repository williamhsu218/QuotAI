import Foundation

/// Checks installed programs without launching them or reading account data.
/// Configuration, usage caches and application-support directories are never
/// evidence of an installation: they can remain after the program is removed.
public enum ProviderInstallationDetector {
    public static func antigravity(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationDirectories: [URL]? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        containsApplication(
            bundleIdentifier: "com.google.antigravity",
            directories: applicationDirectories ?? defaultApplicationDirectories(homeDirectory),
            fileManager: fileManager
        )
    }

    private static func defaultApplicationDirectories(_ homeDirectory: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         homeDirectory.appendingPathComponent("Applications", isDirectory: true)]
    }

    private static func containsApplication(
        bundleIdentifier: String,
        directories: [URL],
        fileManager: FileManager
    ) -> Bool {
        directories.contains { directory in
            guard directory.isFileURL,
                  let applications = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                  ) else { return false }
            return applications.contains { application in
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
        }
    }

    private static func isExecutableFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard url.isFileURL else { return false }
        let resolved = url.resolvingSymlinksInPath()
        guard let attributes = try? fileManager.attributesOfItem(atPath: resolved.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        return fileManager.isExecutableFile(atPath: resolved.path)
    }
}
