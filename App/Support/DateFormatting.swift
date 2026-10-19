import Foundation

@MainActor
enum DisplayDateFormatter {
    private static let activityFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = L10n.locale
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = L10n.isSimplifiedChinese ? "M月d日 EEE" : "EEE, MMM d"
        return formatter
    }()
    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = L10n.locale
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = L10n.isSimplifiedChinese ? "M月" : "MMM"
        return formatter
    }()
    private static let tokenFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = L10n.locale
        formatter.numberStyle = .decimal
        return formatter
    }()
    static func activityDate(_ date: Date) -> String { activityFormatter.string(from: date) }
    static func activityMonth(_ date: Date) -> String { monthFormatter.string(from: date) }
    static func exactTokens(_ count: Int64) -> String { tokenFormatter.string(from: NSNumber(value: count)) ?? "\(count)" }

    private static let beijingCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.setLocalizedDateFormatFromTemplate("MMMdHHmm")
        return formatter
    }()

    private static let localTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.timeZone = .autoupdatingCurrent
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    static func resetText(for date: Date?, now: Date = Date()) -> String {
        guard let date else {
            return L10n.text("date.reset_unknown", fallback: "Reset time unknown")
        }
        if beijingCalendar.isDate(date, inSameDayAs: now) {
            return L10n.format(
                "date.reset_today_format",
                fallback: "Resets: Today %@",
                timeFormatter.string(from: date)
            )
        }
        return L10n.format(
            "date.reset_format",
            fallback: "Resets: %@",
            monthDayFormatter.string(from: date)
        )
    }

    static func expiryText(for date: Date?) -> String {
        guard let date else {
            return L10n.text("reset.expiry_unknown", fallback: "No fixed expiry time")
        }
        return L10n.format(
            "reset.expiry_format",
            fallback: "Expires %@",
            monthDayFormatter.string(from: date)
        )
    }

    static func compactDateTime(_ date: Date?) -> String {
        guard let date else { return "--" }
        return monthDayFormatter.string(from: date)
    }

    static func localTime(_ date: Date) -> String {
        localTimeFormatter.string(from: date)
    }

    static func updatedText(for date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 {
            return L10n.text("date.updated_just_now", fallback: "Updated just now")
        }
        if seconds < 3_600 {
            return L10n.format(
                "date.updated_minutes_format",
                fallback: "Updated %d min ago",
                Int(seconds / 60)
            )
        }
        return L10n.format(
            "date.updated_hours_format",
            fallback: "Updated %d hr ago",
            Int(seconds / 3_600)
        )
    }
}
