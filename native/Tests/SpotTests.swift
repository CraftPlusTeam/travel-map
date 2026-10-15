import Foundation
import Testing
@testable import TravelMapCore

private func spot(_ id: String, latitude: Double = 35, longitude: Double = 135,
                  takenAt: Date? = nil, createdAt: Date = Date(timeIntervalSince1970: 0)) -> Spot {
    Spot(id: id, createdAt: createdAt, userID: nil, title: "景色", latitude: latitude,
         longitude: longitude, photoPath: "test.jpg", takenAt: takenAt)
}

@Suite("撮影地点と鮮度")
struct SpotTests {
    @Test func groupsWithin100MetersUsingNewestAnchor() {
        let old = spot("old", takenAt: Date(timeIntervalSince1970: 100))
        let newest = spot("new", latitude: 35.00027, takenAt: Date(timeIntervalSince1970: 300))
        let distant = spot("distant", latitude: 35.045, takenAt: Date(timeIntervalSince1970: 200))
        let groups = SpotGrouping.groups(from: [old, distant, newest])
        #expect(groups.map(\.id) == ["new", "distant"])
        #expect(groups.first?.spots.map(\.id) == ["new", "old"])
        #expect(groups.first?.latitude == newest.latitude)
    }

    @Test func groupingDoesNotChainBeyondAnchorRadius() {
        // A→B and B→C are each about 80m; A→C is 160m. C must form its own group.
        let a = spot("a", latitude: 0, takenAt: Date(timeIntervalSince1970: 300))
        let b = spot("b", latitude: 0.00072, takenAt: Date(timeIntervalSince1970: 200))
        let c = spot("c", latitude: 0.00144, takenAt: Date(timeIntervalSince1970: 100))
        #expect(SpotGrouping.groups(from: [c, b, a]).map { $0.spots.map(\.id) } == [["a", "b"], ["c"]])
    }

    @Test func fallsBackToCreatedAtAndKeepsTiesStable() {
        let older = spot("old", takenAt: Date(timeIntervalSince1970: 100))
        let fallback = spot("fallback", createdAt: Date(timeIntervalSince1970: 200))
        let tie = spot("tie", takenAt: Date(timeIntervalSince1970: 200))
        #expect(SpotGrouping.groups(from: [older, fallback, tie]).first?.spots.map(\.id) == ["fallback", "tie", "old"])
    }

    @Test func distanceHandlesAntipodesAndDateLine() {
        #expect(SpotGrouping.distanceMeters(latitude: 0, longitude: 0, toLatitude: 0, toLongitude: 0) == 0)
        let antipodal = SpotGrouping.distanceMeters(latitude: 45, longitude: 0, toLatitude: -45, toLongitude: 180)
        #expect(antipodal.isFinite && antipodal > 20_000_000)
        let nearDateLine = SpotGrouping.distanceMeters(latitude: 0, longitude: 179.9999, toLatitude: 0, toLongitude: -179.9999)
        #expect(nearDateLine < 30)
    }

    @Test func invalidCoordinatesAreNotDisplayedOnMap() {
        #expect(SpotGrouping.groups(from: [spot("invalid", latitude: 91)]).isEmpty)
        #expect(SpotGrouping.groups(from: [spot("invalid", longitude: .nan)]).isEmpty)
    }

    @Test func periodsRespectLocalDayAndRollingSevenDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 9 * 3_600))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-16T12:00:00+09:00"))
        let midnight = calendar.startOfDay(for: now)
        let today = spot("today", takenAt: midnight)
        let yesterday = spot("yesterday", takenAt: midnight.addingTimeInterval(-1))
        let boundary = spot("boundary", takenAt: now.addingTimeInterval(-7 * 86_400))
        let outside = spot("outside", takenAt: now.addingTimeInterval(-7 * 86_400 - 1))
        let values = [today, yesterday, boundary, outside]
        #expect(FreshnessPeriod.today.filter(values, now: now, calendar: calendar).map(\.id) == ["today"])
        #expect(FreshnessPeriod.week.filter(values, now: now, calendar: calendar).map(\.id) == ["today", "yesterday", "boundary"])
        #expect(FreshnessPeriod.all.filter(values, now: now, calendar: calendar) == values)
    }

    @Test func codableSupportsLocalISO8601Persistence() throws {
        let source = spot("local", takenAt: Date(timeIntervalSince1970: 500))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(source)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["lat"] as? Double == 35)
        #expect(object["created_at"] is String)
        #expect(object["photo_path"] as? String == "test.jpg")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(Spot.self, from: data) == source)
    }
}
