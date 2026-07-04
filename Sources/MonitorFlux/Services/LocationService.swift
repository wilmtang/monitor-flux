import CoreLocation
import Foundation

/// A one-shot location provider for deriving sunrise/sunset. It requests permission,
/// fetches a single coarse fix, and hands the coordinate back on the main actor.
@MainActor
final class LocationService: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var statusMessage: String

    /// Invoked on the main actor whenever a fresh coordinate arrives.
    var onLocation: (@MainActor (CLLocationCoordinate2D) -> Void)?

    /// Whether a fix can be requested without prompting (permission already granted).
    var isAuthorized: Bool {
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            true
        default:
            false
        }
    }

    private let manager = CLLocationManager()

    override init() {
        authorizationStatus = manager.authorizationStatus
        statusMessage = Self.message(for: manager.authorizationStatus)
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Ask for permission if needed, then fetch a single location.
    func request() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            statusMessage = "Denied — enable in System Settings ▸ Privacy & Security ▸ Location Services."
        @unknown default:
            break
        }
    }

    private func handleAuthorizationChange() {
        authorizationStatus = manager.authorizationStatus
        statusMessage = Self.message(for: manager.authorizationStatus)
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        default:
            break
        }
    }

    private static func message(for status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            "Not requested"
        case .authorizedAlways, .authorizedWhenInUse:
            "Authorized"
        case .denied:
            "Denied"
        case .restricted:
            "Restricted"
        @unknown default:
            "Unknown"
        }
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.handleAuthorizationChange()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else {
            return
        }
        Task { @MainActor in
            self.statusMessage = "Authorized"
            self.onLocation?(coordinate)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.statusMessage = "Error: \(message)"
        }
    }
}
