import Foundation
import KokoroCore
import XCTest
@testable import KokoroWindowsState
#if os(Windows)
import WinSDK
#endif

final class WindowsTimelineDateTests: XCTestCase {
    private func date(_ value: String) throws -> Date {
        try APIJSON.decoder().decode(Date.self, from: Data("\"\(value)\"".utf8))
    }

    func testAPITimestampsWithDifferentOffsetsRepresentTheSameInstant() throws {
        let expected = Date(timeIntervalSince1970: 1_790_608_988.123)
        for value in ["2026-09-28T15:23:08.123Z", "2026-09-29T00:23:08.123+09:00",
                      "2026-09-28T11:23:08.123-04:00"] {
            let parsed = try date(value)
            XCTAssertEqual(parsed.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
            let display = WindowsTimelineDate(parsed, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
            XCTAssertEqual(display.timeText, "00:23")
            XCTAssertEqual(display.dayText, "2026年9月29日(火)")
        }
        XCTAssertEqual(try date("2026-09-29T00:23:08+09:00").timeIntervalSince1970, 1_790_608_988)
    }

    func testDayBoundariesUseLocalDatesRatherThanUTC() throws {
        let zone = TimeZone(identifier: "Asia/Tokyo")!
        let before = WindowsTimelineDate(try date("2026-09-28T14:59:00Z"), timeZone: zone)
        let after = WindowsTimelineDate(try date("2026-09-28T15:01:00Z"), timeZone: zone)
        let morning = WindowsTimelineDate(try date("2026-09-29T00:01:00Z"), timeZone: zone)
        XCTAssertEqual(before.timeText, "23:59")
        XCTAssertEqual(after.timeText, "00:01")
        XCTAssertFalse(before.isSameDay(as: after))
        XCTAssertTrue(after.isSameDay(as: morning))
    }

#if os(Windows)
    private func windowsZone(_ identifier: String) throws -> DYNAMIC_TIME_ZONE_INFORMATION {
        var index: DWORD = 0
        var information = DYNAMIC_TIME_ZONE_INFORMATION()
        while EnumDynamicTimeZoneInformation(index, &information) == ERROR_SUCCESS {
            let name = withUnsafePointer(to: &information.TimeZoneKeyName) {
                $0.withMemoryRebound(to: WCHAR.self, capacity: 128) { String(decodingCString: $0, as: UTF16.self) }
            }
            if name == identifier { return information }
            index += 1
        }
        throw NSError(domain: "Missing Windows time zone: \(identifier)", code: 1)
    }

    func testWindowsTokyoZoneDoesNotDependOnLocalizedNamesOrFoundationDefault() throws {
        var information = try windowsZone("Tokyo Standard Time")
        let instant = try date("2026-09-28T15:23:08.123Z")
        let zone = try XCTUnwrap(WindowsTimelineDate.timeZone(for: instant, information: &information))
        XCTAssertEqual(zone.secondsFromGMT(for: instant), 9 * 3600)
        XCTAssertEqual(WindowsTimelineDate(instant, timeZone: zone).timeText, "00:23")
    }

    func testWindowsOffsetsIncludeNegativeAndFractionalHours() throws {
        let instant = try date("2026-09-28T23:30:00Z")
        for (identifier, bias, expectedTime, expectedDay) in [
            ("Marquesas Standard Time", 570, "14:00", "2026年9月28日(月)"),
            ("Nepal Standard Time", -345, "05:15", "2026年9月29日(火)")
        ] {
            var information = try windowsZone(identifier)
            let zone = try XCTUnwrap(WindowsTimelineDate.timeZone(for: instant, information: &information))
            let display = WindowsTimelineDate(instant, timeZone: zone)
            XCTAssertEqual(zone.secondsFromGMT(for: instant), -bias * 60)
            XCTAssertEqual(display.timeText, expectedTime)
            XCTAssertEqual(display.dayText, expectedDay)
        }
    }

    func testWindowsDaylightSavingUsesMessageDateAndKeepsRepeatedHourOnSameDay() throws {
        var information = try windowsZone("Eastern Standard Time")
        let winter = try date("2026-01-01T12:00:00Z")
        let summer = try date("2026-07-01T12:00:00Z")
        XCTAssertEqual(WindowsTimelineDate.timeZone(for: winter, information: &information)?.secondsFromGMT(for: winter), -5 * 3600)
        XCTAssertEqual(WindowsTimelineDate.timeZone(for: summer, information: &information)?.secondsFromGMT(for: summer), -4 * 3600)
        let first = try date("2026-11-01T05:30:00Z")
        let second = try date("2026-11-01T06:30:00Z")
        let before = WindowsTimelineDate(first, timeZone: try XCTUnwrap(WindowsTimelineDate.timeZone(for: first, information: &information)))
        let after = WindowsTimelineDate(second, timeZone: try XCTUnwrap(WindowsTimelineDate.timeZone(for: second, information: &information)))
        XCTAssertEqual(before.timeText, "01:30")
        XCTAssertEqual(after.timeText, "01:30")
        XCTAssertTrue(before.isSameDay(as: after))
    }

    func testDefaultDisplayMatchesWindowsSystemLocalTime() throws {
        var utc = SYSTEMTIME(), local = SYSTEMTIME()
        GetSystemTime(&utc)
        XCTAssertTrue(SystemTimeToTzSpecificLocalTimeEx(nil, &utc, &local))
        var fileTime = FILETIME()
        XCTAssertTrue(SystemTimeToFileTime(&utc, &fileTime))
        let ticks = UInt64(fileTime.dwHighDateTime) << 32 | UInt64(fileTime.dwLowDateTime)
        let instant = Date(timeIntervalSince1970: Double(ticks) / 10_000_000 - 11_644_473_600)
        let display = WindowsTimelineDate(instant)
        XCTAssertEqual(display.timeText, String(format: "%02d:%02d", Int(local.wHour), Int(local.wMinute)))
        XCTAssertTrue(display.dayText.hasPrefix("\(local.wYear)年\(local.wMonth)月\(local.wDay)日"))
    }
#endif
}
