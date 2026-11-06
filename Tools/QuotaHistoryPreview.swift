import AppKit
import SwiftUI

/// Isolated native history acceptance surface. Uses only synthetic samples and
/// its own bundle preferences; never starts provider queries or the live ledger.
@main
struct QuotaHistoryPreview {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let arguments = CommandLine.arguments
        if arguments.contains("--dark") || arguments.contains("dark") {
            app.appearance = NSAppearance(named: .darkAqua)
        } else if arguments.contains("light") {
            app.appearance = NSAppearance(named: .aqua)
        }
        let model = QuotAIAppModel.preview(history: samples(arguments: arguments))
        model.refreshHistory()
        model.historyWindow.show()
        if arguments.contains("--minimum-size") {
            app.windows.first?.setContentSize(NSSize(width: 720, height: 600))
        }

        // Capture actual window frames during CUA pointer, selection, scrolling,
        // filter and resize checks. Intentional user resizes form new epochs.
        let output = arguments.first { $0.hasPrefix("--evidence=") }
            .map { URL(fileURLWithPath: String($0.dropFirst("--evidence=".count))) }
        let frameLog = FrameLog(output: output)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                frameLog.capture()
            }
        }
        withExtendedLifetime((model, frameLog, timer)) { app.run() }
    }

    private static func samples(arguments: [String]) -> [QuotaHistoryPoint] {
        if arguments.contains("--empty") { return [] }
        let now = Date()
        let sources: [(QuotaProvider, String, String)] = [
            (.codex, "Codex", ""),
            (.claudeCode, "Claude Code", "Claude Opus 5.5"),
            (.antigravity, "Antigravity", "Gemini 3.8 Flash"),
            (.antigravity, "Antigravity", "Gemini 4 Argon · Extended reasoning and long context"),
            (.antigravity, "Antigravity", "Claude Opus 5.5 · Shared model quota pool")
        ]
        let dense = arguments.contains("--dense")
        let count = dense ? 1_200 : 24
        var points: [QuotaHistoryPoint] = []
        for (sourceIndex, source) in sources.enumerated() {
            for kind in QuotaKind.allCases {
                for index in 0..<count {
                    let date = now.addingTimeInterval(-Double(count - 1 - index) * 60)
                    let reset = sourceIndex == 4 ? nil : date.addingTimeInterval(kind == .fiveHour ? 18_000 : 604_800)
                    let percent =
                        dense
                        ? (index * 7 + sourceIndex * 19) % 101
                        : max(0, 95 - sourceIndex * 13 - index * (kind == .fiveHour ? 2 : 1))
                    let point = QuotaHistoryPoint(
                        provider: source.0, providerName: source.1,
                        groupID: "fixture-\(sourceIndex)", groupName: source.2,
                        window: kind, timestamp: date,
                        remainingPercent: percent,
                        resetsAt: reset
                    )
                    points.append(point)
                }
            }
        }
        return points.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
    }
}

@MainActor
private final class FrameLog {
    let output: URL?
    private var observations: [[String: Any]] = []

    init(output: URL?) { self.output = output }

    func capture() {
        guard let output,
            let window = NSApp.windows.first(where: {
                $0.isVisible && $0.title == L10n.text("history.title", fallback: "Quota History")
            })
        else { return }
        let frame = window.frame
        var observation: [String: Any] = [
            "time": Date().timeIntervalSince1970,
            "x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height
        ]
        if let table = findTable(in: window.contentView) {
            observation["tableRows"] = table.numberOfRows
            observation["tableViewportHeight"] = table.visibleRect.height
        }
        observations.append(observation)
        if observations.count > 6_000 { observations.removeFirst(1_000) }
        if let data = try? JSONSerialization.data(withJSONObject: observations, options: [.sortedKeys]) {
            try? data.write(to: output, options: .atomic)
        }
    }

    private func findTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { self.findTable(in: $0) }.first
    }
}
