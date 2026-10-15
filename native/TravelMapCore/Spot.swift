import Foundation

/// A photograph anchored to the place where it was taken. Matches public.spots.
public struct Spot: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let createdAt: Date
    public let userID: String?
    public let title: String
    public let latitude: Double
    public let longitude: Double
    public let photoPath: String
    public let takenAt: Date?

    public init(
        id: String,
        createdAt: Date,
        userID: String?,
        title: String,
        latitude: Double,
        longitude: Double,
        photoPath: String,
        takenAt: Date?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.userID = userID
        self.title = title
        self.latitude = latitude
        self.longitude = longitude
        self.photoPath = photoPath
        self.takenAt = takenAt
    }

    public var freshnessDate: Date { takenAt ?? createdAt }

    enum CodingKeys: String, CodingKey {
        case id, title
        case createdAt = "created_at"
        case userID = "user_id"
        case latitude = "lat"
        case longitude = "lng"
        case photoPath = "photo_path"
        case takenAt = "taken_at"
    }
}

public struct SpotGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let latitude: Double
    public let longitude: Double
    /// Most recent photograph first. The first photograph anchors the group.
    public let spots: [Spot]

    public init(id: String, latitude: Double, longitude: Double, spots: [Spot]) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.spots = spots
    }
}

public enum SpotGrouping {
    public static let radiusMeters: Double = 100

    /// Preserves the existing app's greedy, newest-anchor grouping behavior.
    public static func groups(from spots: [Spot]) -> [SpotGroup] {
        let ordered = spots.enumerated().sorted {
            if $0.element.freshnessDate == $1.element.freshnessDate { return $0.offset < $1.offset }
            return $0.element.freshnessDate > $1.element.freshnessDate
        }
        var grouped: [(anchor: Spot, spots: [Spot])] = []
        for (_, spot) in ordered where isValidCoordinate(spot.latitude, spot.longitude) {
            if let index = grouped.firstIndex(where: {
                distanceMeters(
                    latitude: $0.anchor.latitude, longitude: $0.anchor.longitude,
                    toLatitude: spot.latitude, toLongitude: spot.longitude
                ) <= radiusMeters
            }) {
                grouped[index].spots.append(spot)
            } else {
                grouped.append((anchor: spot, spots: [spot]))
            }
        }
        return grouped.map {
            SpotGroup(id: $0.anchor.id, latitude: $0.anchor.latitude,
                      longitude: $0.anchor.longitude, spots: $0.spots)
        }
    }

    public static func distanceMeters(
        latitude: Double, longitude: Double,
        toLatitude: Double, toLongitude: Double
    ) -> Double {
        let radians = Double.pi / 180
        let deltaLatitude = (toLatitude - latitude) * radians
        let deltaLongitude = (toLongitude - longitude) * radians
        let value = pow(sin(deltaLatitude / 2), 2)
            + cos(latitude * radians) * cos(toLatitude * radians) * pow(sin(deltaLongitude / 2), 2)
        // Clamp floating point roundoff at antipodal coordinates.
        return 2 * 6_371_000 * asin(sqrt(min(1, max(0, value))))
    }

    static func isValidCoordinate(_ latitude: Double, _ longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

public enum FreshnessPeriod: String, CaseIterable, Sendable {
    case all, today, week

    public func filter(
        _ spots: [Spot], now: Date = Date(), calendar: Calendar = .current
    ) -> [Spot] {
        switch self {
        case .all:
            return spots
        case .today:
            let start = calendar.startOfDay(for: now)
            return spots.filter { $0.freshnessDate >= start }
        case .week:
            // A rolling seven days, matching the original app rather than a calendar week.
            let start = now.addingTimeInterval(-7 * 24 * 60 * 60)
            return spots.filter { $0.freshnessDate >= start }
        }
    }
}
