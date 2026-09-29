import Foundation
#if os(Windows)
import WinSDK
#endif

/// Uses Windows' time-zone rules for each message, including historical DST.
/// Foundation's current zone can fall back to GMT on localized Windows installs.
public struct WindowsTimelineDate {
    private let date: Date
    private let calendar: Calendar

    public init(_ date: Date) {
        self.init(date, timeZone: Self.localTimeZone(for: date))
    }

    init(_ date: Date, timeZone: TimeZone) {
        self.date = date
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    public var timeText: String { formatted("HH:mm") }
    public var dayText: String { formatted("yyyy年M月d日(E)") }

    public func isSameDay(as other: WindowsTimelineDate) -> Bool {
        calendar.dateComponents([.era, .year, .month, .day], from: date)
            == other.calendar.dateComponents([.era, .year, .month, .day], from: other.date)
    }

    private func formatted(_ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    static func localTimeZone(for date: Date) -> TimeZone {
#if os(Windows)
        var information = DYNAMIC_TIME_ZONE_INFORMATION()
        if GetDynamicTimeZoneInformation(&information) != TIME_ZONE_ID_INVALID,
           let zone = timeZone(for: date, information: &information) {
            return zone
        }
#endif
        return .current
    }

#if os(Windows)
    static func timeZone(for date: Date, information: inout DYNAMIC_TIME_ZONE_INFORMATION) -> TimeZone? {
        // FILETIME counts 100 ns intervals since 1601. Whole seconds suffice for
        // the offset; leave the original Date (and its fractional seconds) intact.
        let seconds = floor(date.timeIntervalSince1970) + 11_644_473_600
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max / 10_000_000) else { return nil }
        let ticks = UInt64(seconds) * 10_000_000
        var fileTime = FILETIME(dwLowDateTime: UInt32(truncatingIfNeeded: ticks),
                                dwHighDateTime: UInt32(ticks >> 32))
        var utc = SYSTEMTIME(), local = SYSTEMTIME(), localFileTime = FILETIME()
        guard FileTimeToSystemTime(&fileTime, &utc),
              SystemTimeToTzSpecificLocalTimeEx(&information, &utc, &local),
              SystemTimeToFileTime(&local, &localFileTime) else { return nil }
        let localTicks = UInt64(localFileTime.dwHighDateTime) << 32 | UInt64(localFileTime.dwLowDateTime)
        guard localTicks <= UInt64(Int64.max) else { return nil }
        let offset = Int((Int64(localTicks) - Int64(ticks)) / 10_000_000)
        return TimeZone(secondsFromGMT: offset)
    }
#endif
}
