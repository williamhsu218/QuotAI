import Foundation

/// A recovery may only recycle this user's signed QuotAI extension.
/// A matching process name alone is never sufficient.
struct WidgetRecoveryPolicy: Sendable {
    let executablePath: String
    let containerIdentifier: String
    let identifier: String
    let team: String
    let userID: UInt32

    static func responsesConfirmRecovery(
        before: Set<String>?, after: Set<String>?, responses: Set<String>
    ) -> Bool {
        let expected = (before ?? []).union(after ?? [])
        if expected.isEmpty { return before != nil && after != nil }
        return expected.isSubset(of: responses)
    }

    /// Kernel-validated identity survives deletion of the old app by Sparkle.
    /// Local/ad-hoc signatures and unknown validation categories fail closed.
    func allowsKernelIdentity(
        identifier: String?, team: String?, userID: UInt32, flags: UInt32, category: UInt32
    ) -> Bool {
        !self.team.isEmpty && self.identifier == containerIdentifier + ".QuotaWidget"
            && identifier == self.identifier && team == self.team && userID == self.userID
            && flags & 0x2000_0001 == 0x2000_0001 && flags & 0x2 == 0
            && [2, 3, 4, 6].contains(category)
    }

    func allows(
        executablePath: String, containerIdentifier: String?, identifier: String?, team: String?, userID: UInt32
    ) -> Bool {
        let expectedSuffix = "/Contents/PlugIns/QuotAIWidget.appex/Contents/MacOS/QuotAIWidget"
        // Finder moves the previous app aside during replacement. proc_pidpath
        // then reports that relocated path, while its extension remains alive.
        let ownLocation = executablePath == self.executablePath || executablePath.hasSuffix(expectedSuffix)
        return !self.team.isEmpty && ownLocation && self.containerIdentifier == containerIdentifier
            && self.identifier == identifier
            && self.team == team && self.userID == userID
    }
}
