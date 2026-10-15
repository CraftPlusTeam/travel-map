import CoreLocation
import Foundation

@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var isAuthorized = false
    private let manager = CLLocationManager()
    private var pending: CheckedContinuation<CLLocation, Error>?
    private var timeout: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        isAuthorized = [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus)
    }

    func currentLocation() async throws -> CLLocation {
        guard pending == nil else { throw LocationError.busy }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                self?.complete(.failure(LocationError.timedOut))
            }
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
            default: complete(.failure(LocationError.denied))
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        isAuthorized = [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus)
        guard pending != nil else { return }
        if isAuthorized { manager.requestLocation() }
        else if manager.authorizationStatus != .notDetermined { complete(.failure(LocationError.denied)) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last(where: { $0.horizontalAccuracy >= 0 && abs($0.timestamp.timeIntervalSinceNow) < 30 }) else { return }
        complete(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        complete(.failure(error))
    }

    private func complete(_ result: Result<CLLocation, Error>) {
        let continuation = pending
        pending = nil
        timeout?.cancel()
        timeout = nil
        manager.stopUpdatingLocation()
        continuation?.resume(with: result)
    }

    static func placeName(for coordinate: CLLocationCoordinate2D) async -> String? {
        let geocoder = CLGeocoder()
        guard let place = try? await geocoder.reverseGeocodeLocation(
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)).first else { return nil }
        return [place.administrativeArea, place.locality, place.subLocality]
            .compactMap { $0 }.reduce(into: [String]()) { values, value in
                if values.last != value { values.append(value) }
            }.joined(separator: " ").nilIfEmpty
    }
}

enum LocationError: LocalizedError {
    case denied, timedOut, busy
    var errorDescription: String? {
        switch self {
        case .denied: return "位置情報が許可されていません。設定アプリでTravel Mapの位置情報を許可してください。"
        case .timedOut: return "現在地を取得できませんでした。空が見える場所で、もう一度お試しください。"
        case .busy: return "現在地を確認しています。少し待ってからお試しください。"
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
