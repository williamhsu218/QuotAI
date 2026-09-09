# Design QA

## Latest unit correction — 2026-09-09 M / B switching

2.0.10 (27) corrects the fixed-M interpretation in 2.0.9. Antigravity totals,
breakdowns, model summaries and day details automatically use M / B with two
decimals; cache-inclusive counting and layout are unchanged. 60 tests and
English/light plus Chinese/dark four-model card renders passed. The Universal
ZIP was validated and installed with rollback retained.
See [the unit correction record](Design/antigravity-token-units-qa-2.0.10.md).

## Previous UI verification — 2026-09-08 cache-inclusive M token card

2.0.9 (26) uses input + output + cache hits for the Antigravity total,
model summaries and reliably dated daily cells. All values use fixed M units,
with a compact three-column breakdown and honest `<0.01 M` nonzero values.
59 tests, Universal Release, native English/light and Chinese/dark preview checks,
and a four-model large-value card render passed. No new polling, source reads,
cache migration or scrolling container was added. On September 9, the user approved
delivery: the ad-hoc Universal ZIP passed package checks and was installed as 2.0.9,
with the previous application, preferences and v2 cache retained for rollback.
See [the scoped verification and delivery record](Design/antigravity-token-millions-qa-2.0.9.md).

## Previous UI verification — 2026-09-08 centered quota tabs, no scrolling

2.0.8 (25) uses exactly two centered native quota tabs: Gemini and Claude / GPT.
Only one pool is visible, while the local Token grid always covers all models.
The previous height-capped scroll container is removed. Persistent Token footer
explanations are now hover help; compact partial/stale indicators remain visible.
56 Swift tests, Universal Release and isolated native light/dark UI checks passed.
See [the current scoped verification record](Design/antigravity-quota-tabs-qa-2.0.8.md).
The [build 24 date-grid record](Design/antigravity-date-grid-qa-2.0.8.md) retains the
metadata/date evidence, but its scrolling layout has been superseded.
This records the isolated-preview checkpoint before packaging and installation;
it does not itself establish an installed or published release.

## Current scope

- Native SwiftUI menu-bar app for personal use on macOS.
- Displays Codex 5-hour and 7-day quota windows, reset times, reset-credit count, and concrete expiry times.
- Displays Antigravity in a separate provider page, retaining distinct Gemini and Claude/GPT 5-hour and weekly quota pools.
- Lets Settings choose one menu-bar provider and Antigravity group while reusing the existing 5h-only, 7d-only, or both-windows preference.
- Omits the 5-hour row when Codex does not return that window.
- Includes a native Stay Awake control with Caffeine-compatible duration choices.
- Supports English and Simplified Chinese.
- Includes a complete macOS App Icon asset set.
- Does not include an app extension, App Group entitlement, or desktop widget.

## Visual checks

- Uses native San Francisco typography, monospaced digits, semantic weights, and keyboard/focus behavior.
- Uses macOS semantic text, separator, and track colors over a system material surface so the panel follows Light and Dark appearance automatically.
- Keeps the cyan/green quota distinction with softer system teal and system green accents instead of fixed neon colors.
- Uses native Liquid Glass for the menu panel and footer actions on macOS 26+, with the adaptive material surface retained as the macOS 14–15 fallback.
- Places a dedicated transparent 36-point circular HUD mark at the leading edge of the popover title, retaining the App Icon's concentric rings, ticks, circuitry, cyan/lime arcs, central Q, and target dot without carrying its outer rounded-square plate into the Liquid Glass surface.
- Gives the subscription plan a compact indigo-to-cyan-to-mint gradient badge with adaptive text, border, and shadow instead of stacking a second glass surface inside the native popover.
- Preserves quota dividers, progress-bar rhythm, reset-credit grouping, footer alignment, and compact menu-bar presentation.
- Quota rows expose combined accessibility labels and avoid duplicate VoiceOver output.
- Uses system orange only for the Stay Awake icon, active state, switch track, and behavior/duration menus so the utility remains visually separate from quota status.
- Renders the Stay Awake switch with an explicit orange active track and semantic gray inactive track so macOS 26 popover glass cannot flatten both states to gray.
- Keeps the Stay Awake control compact while exposing separate display-behavior and duration menus in both English and Simplified Chinese.
- Settings presents a native bordered GitHub update button beside the current app version. It opens the stable `/releases/latest` page explicitly and performs no background update checks or downloads.
- The popover provider switch is a two-button SwiftUI segmented control with explicit selected-state accessibility; it renders consistently in both the native popover and offline QA renderer.
- Codex reset credits and subscription plan never appear on the Antigravity page; Antigravity model groups never appear on the Codex page.

## Runtime checks

- Build and launch are verified through `./script/build_and_run.sh --verify`.
- The menu-bar process remains active after launch.
- Live Codex refresh is checked through unified logging.
- Live Antigravity 2.8.1 refresh dynamically discovers the loopback HTTPS listener and completes with two recognized groups; logs retain only success/failure type and group count, never authentication, balance, or reset values.
- Antigravity has no disk snapshot. A stopped app, authentication failure, or incompatible protocol clears the in-memory snapshot and shows unavailable instead of zero.
- Local quota caching uses the user's Application Support directory and requires no App Group.
- `pmset -g assertions` confirms that Stay Awake always creates a QuotAI-owned system-sleep assertion, adds a display-sleep assertion only for “Keep display awake,” and removes both on stop or expiry.
- When Stay Awake is active, the menu bar title shows a leading template `cup.and.saucer.fill` icon; it disappears immediately when the feature stops.
- The popover uses a compact 340-point desktop width, with reset expiries arranged in a two-column grid and the reset-count badge trailing the section title.
- Quota percentage text uses adaptive semantic colors: calibrated Display P3 green at 50–100% in both appearances, system orange at 20–49%, and system red below 20%. Progress bars keep the proportional 0–20% critical, 20–50% warning, and 50–100% healthy scale, while narrow cross-boundary blends soften red→orange and orange→green transitions. Adaptive two-tone center ticks preserve a visible threshold separation at 20% and 50% in both Light and Dark Liquid Glass.

## Latest visual comparison — 2026-09-01 interaction and hierarchy polish

- Rendered quota panels: `build/qa/implementation-en-light.png`, `build/qa/implementation-en-dark-antigravity.png`, `build/qa/implementation-zh-Hans-dark.png`, and `build/qa/implementation-zh-Hans-light-antigravity.png`.
- Real native Settings windows: `build/qa/native-settings-general-light.png` and `build/qa/native-settings-providers-dark.png`.
- Refresh behavior: quota values use a reduce-motion-aware numeric transition and progress fills animate over 0.4 seconds. Provider selection and content replacement are synchronous so repeated switching never waits for an outgoing view animation.
- Empty states: loading now has a native small progress indicator, failures have a semantic red anchor and an inline Retry action.
- Visual rhythm: shared spacing, type-size, and motion tokens replace half-step values in the modified views; the Codex and Antigravity pages retain compact 340-point panel geometry without excessive Codex whitespace.
- Status hierarchy: footer icons reuse healthy/critical semantic colors, inactive Stay Awake is neutral, and orange is reserved for its active state.
- Antigravity grouping: each model card has a full-height 2-point cyan or green accent rail, while quota rows remain isolated from Codex resets.
- Footer and Settings: the popover overflow menu contains GitHub update and Quit actions; Settings supports Command-1 through Command-4 tab switching and uses theme status colors.
- Native Settings QA: the Light General pane confirms system Toggle and Picker rendering; the Dark Providers pane confirms the path field, Browse button, integration Toggle, and connection indicators. No yellow renderer placeholders, clipping, or contrast failures remain.
- Dark tracks use a 12% semantic white tint so unused quota capacity remains visible on the dark material surface.
- Sparse-content correction: `build/qa/implementation-en-light-codex-sparse.png` covers the one-window/one-reset state. The quota region now takes its intrinsic height instead of reserving a 232-point minimum, so Stay Awake follows immediately after the reset card without a blank block.

final result: passed

## Interaction upgrade — 2026-09-02 status item quick menu

- Left click retains the existing transient quota popover.
- Right click opens a native menu limited to Stay Awake, Refresh Now, and Settings; Provider selection remains in the visible panel.
- Stay Awake uses native checkmark state, and Refresh Now targets the effective menu bar Provider while disabling itself during an active refresh.
- Closing the menu clears the temporary `NSStatusItem.menu`, restoring the left-click target/action path.
- Native candidate telemetry showed the quick menu opening, Settings dispatching from that menu, and a subsequent left click reopening the active quota popover.
- The installed 2.0.4 (build 16) Universal app matches the accepted candidate binary exactly; launch telemetry confirmed one AppKit status item, restored indefinite Stay Awake state, and successful Codex and Antigravity refreshes.

final result: passed

## Regression fix — 2026-09-02 quick-menu Settings presentation

- Reproduced the 2.0.4 failure through the native status item: AppKit accepted `showSettingsWindow:` and emitted the old success log, but Accessibility reported zero windows.
- The quick-menu action now waits for the menu tracking loop to unwind, then invokes SwiftUI's native Settings menu command identified by its standard Command-comma shortcut instead of relying on the ineffective selector or a localized title.
- Candidate acceptance started from zero windows and produced one visible, main `AXStandardWindow` named `QuotAI Settings`; it remained visible after five seconds.
- Repeating the right-click Settings action kept exactly one settings window and brought it forward without duplication.
- Installed 2.0.5 (build 17) acceptance repeated the zero-to-one-window flow against `/Applications/QuotAI.app`; Accessibility and lifecycle telemetry confirmed the visible main Settings window and native command dispatch.
- Rendered evidence: `build/qa/quick-menu-settings-2.0.5.png`.

final result: passed

## Interaction correction — 2026-09-01 rapid provider switching

- Removed the explicit animation transaction from the Codex/Antigravity buttons and removed the content opacity transitions tied to `effectiveQuotaProvider`.
- The selected segment, provider plan badge, quota content, adaptive height, footer status, and refresh target now update in one synchronous SwiftUI transaction.
- Quota number/progress refresh animations and unrelated Settings/Stay Awake control animations remain enabled.
- Source validation confirms `MenuBarPanelView` has no animation or transition driven by `quotaProvider` or `effectiveQuotaProvider`.

final result: passed

## Latest visual comparison — 2026-08-20 separate Antigravity quota page

- Rendered Codex baseline: `build/qa/implementation-en-light.png` and `build/qa/implementation-zh-Hans-dark.png`.
- Rendered Antigravity page: `build/qa/implementation-en-dark-antigravity.png` and `build/qa/implementation-zh-Hans-light-antigravity.png`.
- Provider separation: the selected Codex page contains only Codex rolling limits, plan, and reset credits. The selected Antigravity page contains only its two model-group sections; each group owns its own 5h and 7d rows.
- Menu-bar preview separation: Codex retains the established `5h … · 7d …` title. Antigravity uses a compact group prefix (`AG-G` or `AG-C/G`) and the same persisted window-mode formatting, so balances are never mislabeled as Codex.
- Light/Dark and English/Simplified Chinese: provider controls, group headings, quota rows, reset text, Stay Awake controls, and footer remain visible without clipping at 340 points.
- The first offline pass exposed a native segmented `Picker` as an unsupported yellow placeholder. Replacing it with accessible SwiftUI buttons removed the renderer/native mismatch.
- The native Settings `Form` remains blank under the offline `ImageRenderer`, a pre-existing renderer limitation. Settings source selection is therefore covered by source/build validation; a complete real-window visual read remains a separate gate.

final result: quota panels passed; real Settings-window visual read remains open

## Previous visual comparison — 2026-08-09 quota gradient and threshold separation

- Source visual truth: `/var/folders/my/jy81s0xx5vj3hzv9yqz4cxkm0000gn/T/codex-clipboard-259a1608-a3b2-4ab6-96b7-8e64a3239670.png`.
- Rendered implementations: `build/qa/implementation-en-light.png` and `build/qa/implementation-en-dark.png`.
- Preserved the established risk proportions: critical 0–20%, warning 20–50%, and healthy 50–100%.
- Replaced the hard color cuts with narrow cross-boundary blends centered around 20% and 50%, creating continuous red→coral→orange and orange→olive→green transitions without making the semantic zones ambiguous.
- Replaced the low-contrast one-color ticks with two-tone adaptive separators: a dark edge plus a fine highlight. The marks remain centered inside the 9-point track and identify both thresholds without splitting the bar into detached segments.
- Light appearance uses deeper Display P3 red, orange, olive, and green values so the scale remains defined on bright system glass.
- Dark appearance raises luminance while retaining a true green endpoint instead of cyan or neon teal; the separator highlight remains visible without blooming.
- Typography, bar geometry, fill masking, percentage semantics, layout, AppMark, subscription badge, and all other panel content remain unchanged.

final result: passed

## Previous visual comparison — 2026-08-06 App Icon and transparent header mark

- Source visual truth: the second generated option in ChatGPT conversation `6a73e8c0-9818-83ee-b141-66aa73c4fbd9`, titled “Neon C-Ring Sci-Fi HUD Icon.”
- Full App Icon master: `Design/AppIcon-master.png`; production sizes: `Assets.xcassets/AppIcon.appiconset`.
- Transparent interface mark master: `Design/AppMark-master.png`; production image set: `Assets.xcassets/AppMark.imageset`.
- Rendered implementations: `build/qa/implementation-en-light.png` and `build/qa/implementation-en-dark.png`.
- Full App Icon result: the selected sci-fi HUD artwork is preserved as the application icon, including its dark rounded-square plate, neon cyan/lime C-ring, circular scale, and restrained circuitry.
- Header result: the complete circular HUD module remains at 36 points, including the concentric rings, fine cyan/lime ticks, circuit traces and nodes, segmented blocks, long luminous arcs, cardinal markers, central C, and target dot. Only the outer rounded-square App Icon plate and exterior shadow are removed.
- Light appearance: the cyan lower arc and lime upper arc remain distinct against bright glass; transparent corners blend cleanly into the panel.
- Dark appearance: the same mark remains crisp without restoring a dark backing tile; its highlights do not flatten into the title or plan badge.
- Small-size result: the complete App Icon remains recognizable at 16 pixels. The header image set uses 256 px and 512 px source renditions so the full HUD detail downscales cleanly at 36 points on Retina displays.
- Correction history: the first transparent header attempt simplified the artwork to a C and target dot and therefore dropped the source's fine lines. That attempt was rejected and replaced with the complete circular HUD extraction shown in the final Light/Dark previews.

final result: passed

## Previous visual comparison — 2026-07-30 quota thresholds

- Source visual truth: `/var/folders/my/jy81s0xx5vj3hzv9yqz4cxkm0000gn/T/codex-clipboard-da528270-e4ce-4301-981a-31baa4a4f896.png`.
- Rendered implementations: `build/qa/implementation-en-light.png` and `build/qa/implementation-en-dark.png`.
- Focused implementation evidence: `build/qa/quota-threshold-implementation-light.png` and `build/qa/quota-threshold-implementation-dark.png`.
- Combined source/implementation evidence: `build/qa/quota-threshold-comparison.png`.
- Viewport: 520 × 690 points at renderer scale 2; each full implementation image is 1040 × 1380 pixels. The source crop is 654 × 114 pixels at its original density. The focused implementation crops are 700 × 130 pixels; both bar tracks are approximately 311 pixels wide in the combined comparison, so the threshold proportions can be judged without rescaling the tracks.
- State: English quota panel in Light and Dark appearance. Source and implementation use different quota percentages and reset dates; those content differences are excluded because the requested target is the fixed scale segmentation.
- Full-view comparison evidence: the complete Light and Dark previews preserve the existing typography, row geometry, track length, layout rhythm, App Icon, subscription badge, reset section, Stay Awake controls, and footer. No unrelated layout or copy changed.
- Focused comparison evidence: the prior near-even scale is replaced by visibly proportional sections—20% red, 30% warning orange, and 50% green. The two boundary markers sit exactly at 20% and 50%, remain centered inside the 9-point track, and are reduced to 5 points high so they read as ticks rather than dividers.
- Fonts and typography: unchanged native San Francisco styles, sizes, weights, and monospaced quota digits.
- Spacing and layout rhythm: unchanged row width and alignment; shorter markers no longer protrude beyond the bar.
- Colors and visual tokens: existing adaptive Liquid Glass-safe red, orange, and appearance-specific Display P3 green remain intact; only their scale locations changed. Percentage text now uses the same 20% and 50% semantic thresholds.
- Image quality and asset fidelity: no image assets changed; the existing bundled App Icon remains sharp in both full previews.
- Copy and content: no product copy changed.

### Comparison history

- Pass 1 finding (P2): the source showed red, orange, and green occupying nearly balanced widths, which did not communicate the requested 20%/50% risk thresholds. The full-height boundary lines also read more strongly than a small scale tick.
- Fix: moved the scale stops and markers to 20% and 50%, allocated the three zones as 20%/30%/50%, shortened the markers from 10 points to 5 points, and synchronized the percentage-text thresholds.
- Pass 2 evidence: the combined comparison and both appearance-specific focused crops show the requested proportions and restrained internal ticks with no remaining P0, P1, or P2 mismatch.

final result: passed

## Localization checks

- English and Simplified Chinese resources cover the app, menu-bar panel, settings, and error states.
- Both languages keep Asia/Shanghai as the quota reset and expiry timezone while using locale-appropriate date text.

## App Icon checks

- Master artwork: `Design/AppIcon-master.png`
- Production asset catalog: `Assets.xcassets/AppIcon.appiconset`
- Header mark master: `Design/AppMark-master.png`
- Header image set: `Assets.xcassets/AppMark.imageset`
- The selected cyan/lime sci-fi HUD Q icon remains recognizable at 16 px, uses no text or third-party logo, and preserves safe padding for macOS rounded-square masking.
- The header image set has a real alpha channel and intentionally excludes the App Icon's black plate.
