import XCTest
@testable import ProbeCore

final class CampusDaylightTests:XCTestCase {
    private func date(_ value:String) -> Date { ISO8601DateFormatter().date(from:value)! }
    private func place(_ lat:Double,_ lon:Double,_ zone:String) -> CampusSunLocation { CampusSunLocation(latitude:lat,longitude:lon,timeZone:TimeZone(identifier:zone)!) }
    func testShanghaiOctoberSolarBoundariesAreLocalAndSwitchPreferenceAtEvents() throws {
        let p = place(31.2304,121.4737,"Asia/Shanghai"),now = date("2026-10-15T04:00:00Z")
        let day = try CampusDaylight.day(containing:now,location:p)
        let sunrise = try XCTUnwrap(day.sunrise),sunset = try XCTUnwrap(day.sunset)
        var calendar = Calendar(identifier:.gregorian);calendar.timeZone = TimeZone(identifier:p.time_zone)!
        XCTAssertEqual(calendar.component(.day,from:sunrise),15)
        XCTAssertTrue((5...7).contains(calendar.component(.hour,from:sunrise)))
        XCTAssertTrue((16...18).contains(calendar.component(.hour,from:sunset)))
        XCTAssertEqual(try CampusDaylight.lighting(at:sunrise.addingTimeInterval(-10),location:p),.night)
        XCTAssertEqual(try CampusDaylight.lighting(at:sunrise.addingTimeInterval(10),location:p),.daylight)
        XCTAssertEqual(try CampusDaylight.lighting(at:sunset.addingTimeInterval(-10),location:p),.daylight)
        XCTAssertEqual(try CampusDaylight.lighting(at:sunset.addingTimeInterval(10),location:p),.night)
        XCTAssertEqual(try CampusDaylight.lighting(at:now,location:p),.daylight)
        XCTAssertEqual(try CampusDaylight.lighting(at:date("2026-10-15T16:00:00Z"),location:p),.night)
    }
    func testSeasonSouthernHemisphereAndPolarDays() throws {
        let sh = place(31.2304,121.4737,"Asia/Shanghai")
        let summer = try CampusDaylight.day(containing:date("2026-06-21T04:00:00Z"),location:sh)
        let winter = try CampusDaylight.day(containing:date("2026-12-21T04:00:00Z"),location:sh)
        XCTAssertGreaterThan(try XCTUnwrap(summer.sunset).timeIntervalSince(try XCTUnwrap(summer.sunrise)),try XCTUnwrap(winter.sunset).timeIntervalSince(try XCTUnwrap(winter.sunrise))+3*3600)
        let syd = place(-33.8688,151.2093,"Australia/Sydney")
        let southSummer = try CampusDaylight.day(containing:date("2026-12-21T01:00:00Z"),location:syd)
        let southWinter = try CampusDaylight.day(containing:date("2026-06-21T02:00:00Z"),location:syd)
        XCTAssertGreaterThan(try XCTUnwrap(southSummer.sunset).timeIntervalSince(try XCTUnwrap(southSummer.sunrise)),try XCTUnwrap(southWinter.sunset).timeIntervalSince(try XCTUnwrap(southWinter.sunrise))+3*3600)
        let polar = place(78.2232,15.6469,"Arctic/Longyearbyen")
        let bright = try CampusDaylight.day(containing:date("2026-06-21T12:00:00Z"),location:polar)
        let dark = try CampusDaylight.day(containing:date("2026-12-21T12:00:00Z"),location:polar)
        XCTAssertNil(bright.sunrise);XCTAssertNil(bright.sunset);XCTAssertTrue(bright.startsInDaylight)
        XCTAssertNil(dark.sunrise);XCTAssertNil(dark.sunset);XCTAssertFalse(dark.startsInDaylight)
        XCTAssertEqual(try CampusDaylight.lighting(at:date("2026-06-21T00:00:00Z"),location:polar),.daylight)
        XCTAssertEqual(try CampusDaylight.lighting(at:date("2026-12-21T12:00:00Z"),location:polar),.night)
    }
    func testCivilDayHandlesDSTAndInternationalDateLine() throws {
        let ny = place(40.7128,-74.006,"America/New_York")
        let spring = try CampusDaylight.day(containing:date("2026-03-08T16:00:00Z"),location:ny)
        let fall = try CampusDaylight.day(containing:date("2026-11-01T17:00:00Z"),location:ny)
        XCTAssertEqual(spring.end.timeIntervalSince(spring.start),23*3600,accuracy:1)
        XCTAssertEqual(fall.end.timeIntervalSince(fall.start),25*3600,accuracy:1)
        for (lat,lon,zone) in [(1.8721,-157.4278,"Pacific/Kiritimati"),(-13.8333,-171.75,"Pacific/Apia")] {
            let p = place(lat,lon,zone),day = try CampusDaylight.day(containing:date("2026-10-15T12:00:00Z"),location:p)
            XCTAssertGreaterThan(try XCTUnwrap(day.sunrise),day.start);XCTAssertLessThan(try XCTUnwrap(day.sunset),day.end)
            XCTAssertLessThan(try XCTUnwrap(day.sunrise),try XCTUnwrap(day.sunset))
        }
    }
    func testManualOverrideMissingLocationAndPreferenceRoundTrip() throws {
        var p = CampusLightingPreference();let zone = TimeZone(identifier:"Asia/Shanghai")!
        XCTAssertEqual(p.preferredLighting(at:date("2026-10-15T04:00:00Z"),timeZone:zone),.daylight)
        XCTAssertEqual(p.preferredLighting(at:date("2026-10-15T15:00:00Z"),timeZone:zone),.night)
        p.location = place(31.23,121.47,"Asia/Shanghai")
        p.mode = .night;XCTAssertEqual(p.preferredLighting(at:date("2026-10-15T04:00:00Z")),.night)
        p.mode = .daylight;XCTAssertEqual(p.preferredLighting(at:date("2026-10-15T15:00:00Z")),.daylight)
        XCTAssertEqual(try JSONDecoder().decode(CampusLightingPreference.self,from:JSONEncoder().encode(p)),p)
    }
    func testInvalidLocationIsRejectedWithoutBreakingFallback() throws {
        var p = place(91,0,"UTC")
        XCTAssertFalse(p.isValid);XCTAssertThrowsError(try CampusDaylight.day(containing:Date(),location:p))
        p.latitude = 0;p.longitude = .nan;XCTAssertThrowsError(try CampusDaylight.lighting(at:Date(),location:p))
        p.longitude = 0;p.time_zone = "invalid/timezone";XCTAssertFalse(p.isValid)
        var preference = CampusLightingPreference();preference.location = p
        XCTAssertEqual(preference.preferredLighting(at:date("2026-10-15T12:00:00Z"),timeZone:TimeZone(secondsFromGMT:0)!),.daylight)
    }
}
