import Foundation

/// Changes only this process's time zone; never changes the Mac's settings.
@main
@MainActor
struct DateFormattingProbe {
    static func main() throws {
        let parser = ISO8601DateFormatter()
        let now = parser.date(from: "2026-11-03T07:30:00Z")!
        let reset = parser.date(from: "2026-11-03T09:30:00Z")!

        func selectZone(_ identifier: String) {
            setenv("TZ", identifier, 1)
            NSTimeZone.resetSystemTimeZone()
            precondition(TimeZone.autoupdatingCurrent.identifier == identifier)
        }

        // Reuse the production's cached formatters across time-zone changes.
        for (zone, time, sameDay) in [
            ("Asia/Shanghai", "17:30", true),
            ("America/Los_Angeles", "01:30", false),
            ("Pacific/Auckland", "22:30", true),
            ("Asia/Shanghai", "17:30", true)
        ] {
            selectZone(zone)
            let text = DisplayDateFormatter.resetText(for: reset, now: now)
            precondition(text.contains(time), "Wrong reset time in \(zone): \(text)")
            precondition(text.contains("Today") == sameDay, "Wrong local calendar day in \(zone): \(text)")
            precondition(DisplayDateFormatter.compactDateTime(reset).contains(time))
            precondition(DisplayDateFormatter.expiryText(for: reset).contains(time))
            precondition(DisplayDateFormatter.activityDate(reset).contains("Nov 3"))
            print("PASS \(zone): local reset/expiry/query time and Today boundary")
        }

        selectZone("America/New_York")
        // Both instants are 01:30 locally, on opposite sides of the DST fold.
        for instant in ["2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z"] {
            let date = parser.date(from: instant)!
            precondition(DisplayDateFormatter.compactDateTime(date).contains("01:30"))
            precondition(DisplayDateFormatter.localTime(date).contains("1:30"))
        }
        precondition(DisplayDateFormatter.compactDateTime(nil) == "--")
        precondition(DisplayDateFormatter.resetText(for: nil) == "Reset time unknown")
        print("PASS DST transition and missing timestamps; process-local TZ only")
    }
}
