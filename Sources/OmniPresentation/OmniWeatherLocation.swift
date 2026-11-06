@preconcurrency import CoreLocation
import Foundation

/// One-shot, while-open location use. No coordinates or placemarks are retained.
@MainActor
public final class OmniWeatherLocation: NSObject, OmniWeatherLocationProviding, @preconcurrency CLLocationManagerDelegate {
    private let remoteServicesEnabled: @MainActor () -> Bool
    private let locationEnabled: @MainActor () -> Bool
    private var manager: CLLocationManager?
    private let geocoder = CLGeocoder()
    private var continuation: CheckedContinuation<WeatherPlace, any Error>?
    private var timeout: Task<Void, Never>?
    private var reverseTask: Task<Void, Never>?
    private var requestID = UUID()

    public init(remoteServicesEnabled: @escaping @MainActor () -> Bool = { true }, locationEnabled: @escaping @MainActor () -> Bool = { true }) {
        self.locationEnabled = locationEnabled
        self.remoteServicesEnabled = remoteServicesEnabled
        super.init()
    }

    public func locate() async throws -> WeatherPlace {
        guard remoteServicesEnabled() else { throw WeatherOfflineError.offline }
        guard locationEnabled() else { throw WeatherLocationFailure.denied }
        cancel()
        try Task.checkCancellation()
        let token = UUID()
        requestID = token
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let manager = CLLocationManager()
                manager.desiredAccuracy = kCLLocationAccuracyKilometer
                manager.delegate = self
                self.manager = manager
                requestIfAuthorized(manager)
                timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    self?.finish(.failure(WeatherLocationFailure.unavailable))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.requestID == token else { return }
                self?.cancel()
            }
        }
    }

    public func cancel() { finish(.failure(CancellationError())) }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager === self.manager else { return }
        requestIfAuthorized(manager)
    }

    private func requestIfAuthorized(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .restricted, .denied: finish(.failure(WeatherLocationFailure.denied))
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        @unknown default: finish(.failure(WeatherLocationFailure.unavailable))
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard manager === self.manager, let location = locations.last, reverseTask == nil else { return }
        manager.stopUpdatingLocation()
        reverseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let placemark = try? await self.geocoder.reverseGeocodeLocation(location).first
            guard !Task.isCancelled, self.manager === manager else { return }
            self.finish(.success(WeatherPlace(
                name: placemark?.locality ?? placemark?.administrativeArea ?? "Current location",
                country: placemark?.country ?? "", admin1: placemark?.administrativeArea ?? "",
                latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                timezone: placemark?.timeZone?.identifier ?? TimeZone.current.identifier,
                neighbourhood: placemark?.subLocality, isCurrentLocation: true
            )))
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        guard manager === self.manager else { return }
        finish(.failure((error as? CLError)?.code == .denied ? WeatherLocationFailure.denied : .unavailable))
    }

    private func finish(_ result: Result<WeatherPlace, any Error>) {
        let pending = continuation
        continuation = nil
        timeout?.cancel()
        timeout = nil
        reverseTask?.cancel()
        reverseTask = nil
        geocoder.cancelGeocode()
        manager?.stopUpdatingLocation()
        manager?.delegate = nil
        manager = nil
        pending?.resume(with: result)
    }
}
