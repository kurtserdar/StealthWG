#if os(iOS)
import Combine
import CoreLocation
import NetworkExtension

/// Fetches the current Wi-Fi SSID, requesting Location When-In-Use if needed. iOS
/// gates SSID reads behind location authorization plus the Access WiFi Information
/// entitlement. ObservableObject so a view can hold it with @StateObject.
final class CurrentWiFi: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum FetchResult { case success(String), denied, unavailable }

    private let manager = CLLocationManager()
    private var completion: ((FetchResult) -> Void)?

    func fetch(_ completion: @escaping (FetchResult) -> Void) {
        self.completion = completion
        manager.delegate = self
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            readSSID()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            finish(.denied)
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            readSSID()
        case .notDetermined:
            break
        default:
            finish(.denied)
        }
    }

    private func readSSID() {
        NEHotspotNetwork.fetchCurrent { [weak self] net in
            if let ssid = net?.ssid, !ssid.isEmpty {
                self?.finish(.success(ssid))
            } else {
                self?.finish(.unavailable)
            }
        }
    }

    private func finish(_ r: FetchResult) {
        let c = completion
        completion = nil
        DispatchQueue.main.async { c?(r) }
    }
}
#endif
