import Foundation

/// A recovery may only recycle this user's signed QuotAI extension.
/// A matching process name alone is never sufficient.
struct WidgetRecoveryPolicy: Sendable {
    let executablePath: String
    let containerIdentifier: String
    let identifier: String
    let team: String
    let userID: UInt32

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
