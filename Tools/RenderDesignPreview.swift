import AppKit
import SwiftUI

@main
@MainActor
struct RenderDesignPreview {
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else {
            fputs("usage: RenderDesignPreview <output.png>\n", stderr)
            exit(2)
        }

        let provider: QuotaProvider = CommandLine.arguments.contains("--antigravity")
            ? .antigravity
            : .codex
        UserDefaults.standard.set(provider.rawValue, forKey: QuotaProvider.panelDefaultsKey)
        UserDefaults.standard.set(provider.rawValue, forKey: QuotaProvider.menuBarDefaultsKey)
        if provider == .antigravity {
            UserDefaults.standard.set(CommandLine.arguments.contains("--ag-claude") ? "3p" : "gemini",
                                      forKey: AntigravityQuotaGroup.panelGroupDefaultsKey)
            UserDefaults.standard.set(
                CommandLine.arguments.contains("--ag-claude") ? "3p" : "gemini",
                forKey: AntigravityQuotaGroup.menuBarGroupDefaultsKey
            )
        }
        UserDefaults.standard.set(true, forKey: QuotaProvider.antigravityIntegrationDefaultsKey)
        UserDefaults.standard.set(MenuBarQuotaDisplayMode.both.rawValue,
                                  forKey: MenuBarQuotaDisplayMode.defaultsKey)

        let store = UsageStore(
            previewMode: true,
            previewSnapshot: CommandLine.arguments.contains("--sparse")
                ? sparseCodexSnapshot
                : nil
        )
        let antigravityStore = AntigravityUsageStore(previewMode: true)
        let tokenState = CommandLine.arguments.contains("--ag-tokens-partial")
            ? AntigravityTokenSnapshot(models: [
                .init(id: "Gemini", input: 100_000_000, output: 10_000_000, cacheRead: 300_000_000, generations: 1000),
                .init(id: "Claude", input: 100_000_000, output: 10_000_000, cacheRead: 300_000_000, generations: 1000),
                .init(id: "GPT", input: 100_000_000, output: 10_000_000, cacheRead: 300_000_000, generations: 1000),
                .init(id: "Other", input: 100_000_000, output: 10_000_000, cacheRead: 300_000_000, generations: 1000)
              ], files: 34, pendingFiles: 30, unavailableFiles: 1, skippedRecords: 2,
                 limited: true, checkedAt: Date(), rowsRead: 512, bytesRead: 768 * 1024,
                 stepRowsRead: 256, dailyBuckets: AntigravityTokenSnapshot.previewBuckets(total: 1_600_000_000),
                 undatedGenerations: 30)
            : nil
        let tokenPreviewStore = AntigravityUsageStore(previewMode: true,
            tokenUsage: AntigravityTokenStore(previewMode: true, previewSnapshot: tokenState))
        let stayAwakeStore = StayAwakeStore(previewMode: true)
        let colorScheme: ColorScheme = CommandLine.arguments.contains("--dark") ? .dark : .light
        NSApplication.shared.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        if CommandLine.arguments.contains("--menubar-matrix") {
            try write(menuBarMatrix(colorScheme: colorScheme), size: CGSize(width: 480, height: 400))
        } else if CommandLine.arguments.contains("--ag-tokens-card") {
            let size = CGSize(width: 340, height: 420)
            try write(
                AntigravityTokenUsageView(store: tokenPreviewStore.tokenUsage)
                    .padding(16)
                    .frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, colorScheme)
                    .environment(\.nativeGlassRenderingEnabled, false),
                size: size
            )
        } else if CommandLine.arguments.contains("--settings") {
            let size = CGSize(width: 480, height: 420)
            let initialTab: SettingsTab = CommandLine.arguments.contains("--about") ? .about
                : CommandLine.arguments.contains("--menu-bar") ? .menuBar
                : CommandLine.arguments.contains("--providers") ? .providers : .general
            try write(
                SettingsView(
                    store: store,
                    antigravityStore: antigravityStore,
                    stayAwakeStore: stayAwakeStore,
                    initialTab: initialTab
                )
                    .environment(\.colorScheme, colorScheme)
                    .environment(\.nativeGlassRenderingEnabled, false)
                    .frame(width: size.width, height: size.height),
                size: size
            )
        } else {
            let size = CGSize(width: 520, height: provider == .antigravity ? 840 : 760)
            try write(
                DesignPreviewView(
                    store: store,
                    antigravityStore: tokenPreviewStore,
                    stayAwakeStore: stayAwakeStore
                )
                    .environment(\.colorScheme, colorScheme)
                    .environment(\.nativeGlassRenderingEnabled, false)
                    .environment(\.designPreviewRendering, true)
                    .frame(width: size.width, height: size.height),
                size: size
            )
        }
    }

    /// Synthetic states only; uses the production renderer, never live provider reads.
    private static func menuBarMatrix(colorScheme: ColorScheme) -> some View {
        let ag = AntigravityQuotaSnapshot.preview
        let onlyGemini = AntigravityQuotaSnapshot(fetchedAt: ag.fetchedAt, groups: [ag.groups[0]])
        let unknown = AntigravityQuotaSnapshot(fetchedAt: ag.fetchedAt, groups: [
            .init(id: "future", displayName: "Future pool",
                  fiveHour: .init(kind: .fiveHour, remainingPercent: 100, resetsAt: nil),
                  sevenDay: .init(kind: .sevenDay, remainingPercent: 0, resetsAt: nil))
        ])
        func value(_ provider: QuotaProvider, group: String? = "gemini",
                   codex: UsageSnapshot? = .preview, snapshot: AntigravityQuotaSnapshot? = .preview,
                   awake: Bool = true) -> MenuBarPresentation {
            MenuBarPresentation(provider: provider, antigravityEnabled: true, antigravityAvailable: true,
                selectedGroupID: group, mode: .both, codexSnapshot: codex, antigravitySnapshot: snapshot,
                isStayAwakeActive: awake)
        }
        let cases: [(String, MenuBarPresentation)] = [
            ("Codex · two windows", value(.codex)),
            ("Codex · weekly only", value(.codex, codex: sparseCodexSnapshot)),
            ("Gemini · awake off", value(.antigravity, awake: false)),
            ("Claude / GPT", value(.antigravity, group: "3p")),
            ("Removed Claude → Gemini", value(.antigravity, group: "3p", snapshot: onlyGemini)),
            ("Unknown pool · 100% / 0%", value(.antigravity, snapshot: unknown)),
            ("Codex · no data", value(.codex, codex: nil)),
            ("Antigravity · no data", value(.antigravity, snapshot: nil))
        ]
        return VStack(spacing: 12) {
            ForEach(Array(cases.enumerated()), id: \.offset) { _, item in
                HStack {
                    Text(item.0).font(.system(size: 12))
                    Spacer()
                    MenuBarStatusLabel(presentation: item.1)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(24)
        .frame(width: 480, height: 400)
        .foregroundStyle(Color.primary)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, colorScheme)
    }

    private static var sparseCodexSnapshot: UsageSnapshot {
        let calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            var components = DateComponents()
            components.calendar = calendar
            components.timeZone = timeZone
            components.year = 2026
            components.month = 9
            components.day = day
            components.hour = hour
            components.minute = minute
            return components.date!
        }

        return UsageSnapshot(
            fetchedAt: date(1, 16, 0),
            fiveHour: nil,
            sevenDay: QuotaWindow(
                kind: .sevenDay,
                remainingPercent: 75,
                resetsAt: date(7, 10, 29)
            ),
            subscriptionPlan: SubscriptionPlan(identifier: "prolite"),
            availableResetCount: 1,
            resetCredits: [
                ResetCredit(
                    grantedAt: date(1, 8, 23),
                    expiresAt: date(21, 8, 23),
                    status: "available"
                )
            ]
        )
    }

    private static func write<Content: View>(_ content: Content, size: CGSize) throws {
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 2

        guard let image = renderer.cgImage else {
            fputs("could not render preview\n", stderr)
            exit(1)
        }
        let representation = NSBitmapImageRep(cgImage: image)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            fputs("could not encode design preview\n", stderr)
            exit(1)
        }

        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
    }
}
