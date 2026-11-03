import CoreServices
import Darwin
import Foundation
import OSLog
import Security

enum WidgetExtensionRecovery {
    struct Result: Sendable {
        let registered: Bool
        let recycledProcesses: Int
    }

    /// Runs off the main actor. No global registry rebuild, daemon restart or
    /// widget-container deletion: only our app's registration and extension.
    static func perform(bundleURL: URL) -> Result {
        let logger = Logger(subsystem: "com.willhsu.QuotAI", category: "WidgetRecovery")
        guard let bundle = Bundle(url: bundleURL), let appID = bundle.bundleIdentifier else {
            return Result(registered: false, recycledProcesses: 0)
        }
        let status = LSRegisterURL(bundleURL as CFURL, true)
        logger.info("Updated own app registration; status=\(status, privacy: .public)")
        let executable = bundleURL.appendingPathComponent(
            "Contents/PlugIns/QuotAIWidget.appex/Contents/MacOS/QuotAIWidget")
        guard let ownInfo = signingInfo(pid: getpid()),
            let team = ownInfo[kSecCodeInfoTeamIdentifier as String] as? String
        else { return Result(registered: status == noErr, recycledProcesses: 0) }
        let policy = WidgetRecoveryPolicy(
            executablePath: executable.resolvingSymlinksInPath().path,
            containerIdentifier: appID,
            identifier: appID + ".QuotaWidget", team: team, userID: getuid())
        let requirementText =
            "anchor apple generic and identifier \"\(policy.identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
            let requirement
        else { return Result(registered: status == noErr, recycledProcesses: 0) }
        var count = 0
        let capacity = max(256, Int(proc_listallpids(nil, 0)) + 128)
        var pids = [pid_t](repeating: 0, count: capacity)
        let actual = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        for pid in pids.prefix(max(0, min(capacity, Int(actual)))) where pid > 0 && pid != getpid() {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let processPath = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard processPath.hasSuffix("/Contents/PlugIns/QuotAIWidget.appex/Contents/MacOS/QuotAIWidget") else {
                continue
            }
            var container = URL(fileURLWithPath: processPath)
            for _ in 0..<6 { container.deleteLastPathComponent() }
            var info = proc_bsdinfo()
            guard
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
                    == MemoryLayout.size(ofValue: info),
                let signature = signingInfo(pid: pid, requirement: requirement),
                policy.allows(
                    executablePath: processPath, containerIdentifier: Bundle(url: container)?.bundleIdentifier,
                    identifier: signature[kSecCodeInfoIdentifier as String] as? String,
                    team: signature[kSecCodeInfoTeamIdentifier as String] as? String, userID: info.pbi_uid)
            else { continue }
            // Widget extensions outlive their containing app. A stale mapped
            // executable can keep producing archives for the previous build.
            if kill(pid, SIGTERM) == 0 {
                count += 1
                logger.info("Recycled verified own widget extension; pid=\(pid, privacy: .public)")
            }
        }
        return Result(registered: status == noErr, recycledProcesses: count)
    }

    private static func signingInfo(pid: pid_t, requirement: SecRequirement? = nil) -> [String: Any]? {
        var code: SecCode?
        guard
            SecCodeCopyGuestWithAttributes(
                nil, [kSecGuestAttributePid as String: pid] as CFDictionary, [], &code) == errSecSuccess,
            let code
        else { return nil }
        var info: CFDictionary?
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        if let requirement {
            guard SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess else { return nil }
        }
        guard
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess
        else { return nil }
        return info as? [String: Any]
    }
}
