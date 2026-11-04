import Darwin
import Foundation
import OSLog
import Security

enum WidgetExtensionRecovery {
    struct Result: Sendable {
        let extensionReady: Bool
        let recycledProcesses: Int
    }

    /// Runs off the main actor. Registration belongs to the system installer;
    /// recovery only recycles this user's verified own extension.
    static func perform(bundleURL: URL) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: repair(bundleURL: bundleURL))
            }
        }
    }

    private static func repair(bundleURL: URL) -> Result {
        let logger = Logger(subsystem: "com.willhsu.QuotAI", category: "WidgetRecovery")
        guard let bundle = Bundle(url: bundleURL), let appID = bundle.bundleIdentifier else {
            return Result(extensionReady: false, recycledProcesses: 0)
        }
        let executable = bundleURL.appendingPathComponent(
            "Contents/PlugIns/QuotAIWidget.appex/Contents/MacOS/QuotAIWidget")
        guard let ownInfo = signingInfo(pid: getpid()),
            let team = ownInfo[kSecCodeInfoTeamIdentifier as String] as? String
        else {
            logger.error("Widget recovery could not determine the containing app signing team")
            return Result(extensionReady: false, recycledProcesses: 0)
        }
        let policy = WidgetRecoveryPolicy(
            executablePath: executable.resolvingSymlinksInPath().path,
            containerIdentifier: appID,
            identifier: appID + ".QuotaWidget", team: team, userID: getuid())
        let requirementText =
            "anchor apple generic and identifier \"\(policy.identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
            let requirement
        else {
            logger.error("Widget recovery could not construct the extension signing requirement")
            return Result(extensionReady: false, recycledProcesses: 0)
        }
        let extensionURL = bundleURL.appendingPathComponent("Contents/PlugIns/QuotAIWidget.appex")
        var extensionCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(extensionURL as CFURL, [], &extensionCode) == errSecSuccess,
            let extensionCode,
            SecStaticCodeCheckValidity(extensionCode, [], requirement)
                == errSecSuccess
        else {
            logger.error("Widget recovery rejected the current extension signature")
            return Result(extensionReady: false, recycledProcesses: 0)
        }
        var count = 0
        var stopped: [ProcessStamp] = []
        let capacity = max(256, Int(proc_listallpids(nil, 0)) + 128)
        var pids = [pid_t](repeating: 0, count: capacity)
        let actual = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        for pid in pids.prefix(max(0, min(capacity, Int(actual)))) where pid > 0 && pid != getpid() {
            guard let stamp = processStamp(pid: pid),
                isOwnedExtension(pid: pid, policy: policy, requirement: requirement),
                processStamp(pid: pid) == stamp
            else { continue }
            // Widget extensions outlive their containing app. A stale mapped
            // executable can keep producing archives for the previous build.
            if kill(pid, SIGTERM) == 0 {
                count += 1
                stopped.append(stamp)
                logger.info("Recycled verified own widget extension; pid=\(pid, privacy: .public)")
            }
        }
        // Wait for the old extension to exit before the system asks it for
        // descriptors. Timeline reloads alone don't invalidate that cache.
        for _ in 0..<40 {
            if stopped.allSatisfy({ processStamp(pid: $0.pid) != $0 }) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let exited = stopped.allSatisfy({ processStamp(pid: $0.pid) != $0 })
        if !exited {
            logger.error("Previous widget extension has not exited; recovery will be retried")
        }
        // Even force-registering a running host can invalidate saved AppIntent
        // LinkActions (1101/1103). Do not call lsregister, LSRegisterURL or
        // pluginkit here; preserve system registration and saved selections.
        logger.info(
            "Prepared verified widget extension without registry changes; ready=\(exited, privacy: .public), recycled=\(count, privacy: .public)"
        )
        return Result(extensionReady: exited, recycledProcesses: count)
    }

    private struct ProcessStamp: Equatable {
        let pid: pid_t
        let seconds: UInt64
        let microseconds: UInt64
    }

    private static func processInfo(pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        guard
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
                == MemoryLayout.size(ofValue: info), info.pbi_status != 5
        else { return nil }
        return info
    }

    private static func processStamp(pid: pid_t) -> ProcessStamp? {
        guard let info = processInfo(pid: pid) else { return nil }
        return .init(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    static func isOwnedExtension(
        pid: pid_t, policy: WidgetRecoveryPolicy, requirement: SecRequirement? = nil
    ) -> Bool {
        guard let info = processInfo(pid: pid), info.pbi_uid == policy.userID else { return false }
        // csops reads AMFI's live identity rather than a replaceable/deleted
        // executable on disk. Require an Apple-validated signing category,
        // signed+valid status, exact extension ID, team and current user.
        if let identifier = kernelString(pid: pid, operation: 11), identifier != policy.identifier { return false }
        if let identifier = kernelString(pid: pid, operation: 11),
            let team = kernelString(pid: pid, operation: 14),
            let flags = kernelWord(pid: pid, operation: 0),
            let category = kernelWord(pid: pid, operation: 17),
            policy.allowsKernelIdentity(
                identifier: identifier, team: team, userID: info.pbi_uid, flags: flags, category: category)
        {
            return true
        }
        // On systems without the kernel query, retain the stricter disk-based
        // path. Never fall back to a process name or an unvalidated team claim.
        guard let requirement else { return false }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        let processPath = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard processPath.hasSuffix("/Contents/PlugIns/QuotAIWidget.appex/Contents/MacOS/QuotAIWidget"),
            let signature = signingInfo(pid: pid, requirement: requirement)
        else { return false }
        var container = URL(fileURLWithPath: processPath)
        for _ in 0..<6 { container.deleteLastPathComponent() }
        return policy.allows(
            executablePath: processPath, containerIdentifier: Bundle(url: container)?.bundleIdentifier,
            identifier: signature[kSecCodeInfoIdentifier as String] as? String,
            team: signature[kSecCodeInfoTeamIdentifier as String] as? String, userID: info.pbi_uid)
    }

    // These read-only operations are defined in Apple's XNU codesign.h.
    // Resolve the optional system interface at runtime and fail closed.
    private typealias CSOps = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer?, Int) -> Int32

    private static func kernelRead(pid: pid_t, operation: UInt32, buffer: UnsafeMutableRawBufferPointer) -> Bool {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops") else { return false }
        let read = unsafeBitCast(symbol, to: CSOps.self)
        return read(pid, operation, buffer.baseAddress, buffer.count) == 0
    }

    private static func kernelWord(pid: pid_t, operation: UInt32) -> UInt32? {
        var value: UInt32 = 0
        let success = withUnsafeMutableBytes(of: &value) { kernelRead(pid: pid, operation: operation, buffer: $0) }
        return success ? value : nil
    }

    private static func kernelString(pid: pid_t, operation: UInt32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 1_024)
        guard buffer.withUnsafeMutableBytes({ kernelRead(pid: pid, operation: operation, buffer: $0) }) else {
            return nil
        }
        let length = buffer[4..<8].reduce(0) { ($0 << 8) | Int($1) }
        guard (9...buffer.count).contains(length), buffer[length - 1] == 0 else { return nil }
        return String(bytes: buffer[8..<(length - 1)], encoding: .utf8)
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
            guard
                SecStaticCodeCheckValidity(staticCode, [], requirement)
                    == errSecSuccess
            else { return nil }
        }
        guard
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess
        else { return nil }
        return info as? [String: Any]
    }
}
