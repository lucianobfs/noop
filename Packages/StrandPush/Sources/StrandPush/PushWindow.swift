import Foundation

/// A declared replace-window bound, half-open: `startInclusive <= selector < endExclusive`.
/// Port of the Kotlin `PushWindow` (`PushModels.kt`) restricted to the mutable-stream shape;
/// there is no `PushCursor`/append counterpart in this package (see the README).
public struct PushWindow: Equatable, Sendable {
    public let fromDay: String
    public let toDay: String
    public let startTsInclusive: Int64
    public let endTsExclusive: Int64

    public init(fromDay: String, toDay: String, startTsInclusive: Int64, endTsExclusive: Int64) {
        self.fromDay = fromDay
        self.toDay = toDay
        self.startTsInclusive = startTsInclusive
        self.endTsExclusive = endTsExclusive
    }

    /// The rolling window ending on `today`, `windowDays` local calendar days wide (the protocol's
    /// default is 14: today plus the preceding 13 days).
    public static func ending(today: Date, timeZone: TimeZone, windowDays: Int) -> PushWindow {
        precondition(windowDays >= 1)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let todayStart = calendar.startOfDay(for: today)
        let fromStart = calendar.date(byAdding: .day, value: -(windowDays - 1), to: todayStart)!
        let endExclusiveStart = calendar.date(byAdding: .day, value: 1, to: todayStart)!
        let formatter = Self.dayFormatter(timeZone: timeZone)
        return PushWindow(
            fromDay: formatter.string(from: fromStart),
            toDay: formatter.string(from: todayStart),
            startTsInclusive: Int64(fromStart.timeIntervalSince1970),
            endTsExclusive: Int64(endExclusiveStart.timeIntervalSince1970)
        )
    }

    /// A window spanning the closed day range `[from, to]`, both inclusive `YYYY-MM-DD` days.
    public static func days(from: String, to: String, timeZone: TimeZone) throws -> PushWindow {
        let formatter = Self.dayFormatter(timeZone: timeZone)
        guard let fromDate = formatter.date(from: from), let toDate = formatter.date(from: to),
              fromDate <= toDate
        else {
            throw PushProtocolError.invalid("window bounds are invalid")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let endExclusiveStart = calendar.date(byAdding: .day, value: 1, to: toDate)!
        return PushWindow(
            fromDay: from,
            toDay: to,
            startTsInclusive: Int64(fromDate.timeIntervalSince1970),
            endTsExclusive: Int64(endExclusiveStart.timeIntervalSince1970)
        )
    }

    static func dayFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    /// `day` plus one calendar day, in pure `YYYY-MM-DD` arithmetic — timezone-independent
    /// because a day KEY is already a calendar date, not an instant. Used only for the wire
    /// `window.endExclusive` string on day-selector streams.
    static func nextDay(_ day: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = day.split(separator: "-").compactMap { Int($0) }
        precondition(parts.count == 3, "day must be YYYY-MM-DD")
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        let date = calendar.date(from: components)!
        let next = calendar.date(byAdding: .day, value: 1, to: date)!
        let nextComponents = calendar.dateComponents([.year, .month, .day], from: next)
        return String(format: "%04d-%02d-%02d", nextComponents.year!, nextComponents.month!, nextComponents.day!)
    }
}
