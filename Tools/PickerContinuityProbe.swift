import AppKit
import QuartzCore
import Foundation

@main struct PickerContinuityProbe {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: PickerContinuityProbe <result.json>\n", stderr)
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 308, height: 36),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = PickerHighlightView()
        window.contentView = view
        window.orderFront(nil)
        view.configure(index: 0, count: 3, spacing: 8, radius: 7, duration: 0.18, reduceMotion: false)
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.06))
        let layer = view.layer!.sublayers!.first { $0.name == "selectionHighlight" }!
        precondition(layer.presentation() != nil, "Need a rendered presentation layer")
        view.configure(index: 2, count: 3, spacing: 8, radius: 7, duration: 0.18, reduceMotion: false)
        let firstStart = (layer.animation(forKey: "selection.slide") as! CABasicAnimation).fromValue as! NSNumber
        var samples: [[String: Double]] = []
        let start = CACurrentMediaTime()
        var reversed = false
        var discontinuity: Double = 0
        var oldX = firstStart.doubleValue
        while CACurrentMediaTime() - start < 0.34 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.008))
            let t = CACurrentMediaTime() - start
            let x = layer.presentation()!.position.x
            if !reversed && t >= 0.072 {
                view.configure(index: 0, count: 3, spacing: 8, radius: 7, duration: 0.18, reduceMotion: false)
                let from = (layer.animation(forKey: "selection.slide") as! CABasicAnimation).fromValue as! NSNumber
                discontinuity = abs(from.doubleValue - x)
                precondition(discontinuity < 0.01, "Reversal jumped away from the presentation position")
                reversed = true
                oldX = from.doubleValue
            } else {
                // SwiftUI can configure/layout the same selection repeatedly.
                // Those updates must preserve the animation's original start.
                let before = layer.animation(forKey: "selection.slide") as? CABasicAnimation
                view.configure(index: reversed ? 0 : 2, count: 3, spacing: 8, radius: 7, duration: 0.18, reduceMotion: false)
                view.setFrameSize(NSSize(width: 308, height: samples.count.isMultiple(of: 2) ? 36 : 37))
                view.needsLayout = true
                view.layoutSubtreeIfNeeded()
                let after = layer.animation(forKey: "selection.slide") as? CABasicAnimation
                if let before, let after {
                    precondition((before.fromValue as! NSNumber) == (after.fromValue as! NSNumber), "Layout restarted the animation")
                }
                if reversed { precondition(x <= oldX + 0.5, "Unexpected backwards jitter after reversal") }
                else { precondition(x >= oldX - 0.5, "Unexpected backwards jitter while sliding right") }
                oldX = x
            }
            samples.append(["time": t, "x": x])
        }
        let target = layer.position.x
        precondition(abs(layer.presentation()!.position.x - target) < 0.5, "Highlight failed to settle")
        view.configure(index: 2, count: 3, spacing: 8, radius: 7, duration: 0.18, reduceMotion: true)
        precondition(layer.animation(forKey: "selection.slide") == nil, "Reduce Motion still animated")
        window.orderOut(nil)
        let result: [String: Any] = ["passed": true, "samples": samples, "reversalPositionDelta": discontinuity,
                                   "repeatedLayoutPreservedAnimation": true, "reduceMotionRemovedAnimation": true]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("PASS: \(samples.count) presentation samples; continuous reversal; layout updates preserve animation; reduce motion immediate")
    }
}
