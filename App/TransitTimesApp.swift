import SwiftUI
import MapKit
import CoreLocation
import WidgetKit

@main
struct TransitTimesApp: App {
    init() { LocationProvider.shared.start() }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()
    @Published var coordinate: CLLocationCoordinate2D? = Shared.lastLocation
    private let mgr = CLLocationManager()

    func start() {
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters
        mgr.distanceFilter = 200
        mgr.pausesLocationUpdatesAutomatically = true
        mgr.requestWhenInUseAuthorization()
        mgr.startUpdatingLocation()
        // Keeps the widget's origin fresh even when the app is closed (needs "Always").
        if mgr.authorizationStatus == .authorizedAlways { mgr.startMonitoringSignificantLocationChanges() }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) {
        guard let c = l.last?.coordinate else { return }
        let moved = Shared.lastLocation.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: l.last!) } ?? .infinity
        coordinate = c
        Shared.lastLocation = c
        if moved > 500 { WidgetCenter.shared.reloadAllTimelines() }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .authorizedWhenInUse:
            m.requestAlwaysAuthorization()
            m.startUpdatingLocation()
        case .authorizedAlways:
            m.startUpdatingLocation()
            m.startMonitoringSignificantLocationChanges()
        default: break
        }
    }
    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {}
}

@MainActor
final class TransitModel: ObservableObject {
    @Published var destinations = Shared.destinations { didSet { Shared.destinations = destinations; WidgetCenter.shared.reloadAllTimelines() } }
    @Published var results = Shared.cachedResults
    @Published var loading = false
    @Published var leaveMinutes = Shared.leaveMinutes { didSet { Shared.leaveMinutes = leaveMinutes } }
    @Published var arriveMinutes = Shared.arriveMinutes { didSet { Shared.arriveMinutes = arriveMinutes } }
    private var lastRefreshOrigin: CLLocationCoordinate2D?
    private var lastRefreshDate = Date.distantPast

    @Published var apiKey = Shared.apiKey { didSet { Shared.apiKey = apiKey } }

    /// Refresh only if forced, or the user moved >300 m, or data is >2 min old.
    func refreshIfNeeded(from origin: CLLocationCoordinate2D?) async {
        guard let origin else { return }
        let moved = lastRefreshOrigin.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                .distance(from: CLLocation(latitude: origin.latitude, longitude: origin.longitude))
        } ?? .infinity
        if moved > 300 || Date().timeIntervalSince(lastRefreshDate) > 120 { await refresh(from: origin) }
    }

    func refresh(from origin: CLLocationCoordinate2D?) async {
        guard let origin, !apiKey.isEmpty else { return }
        loading = true
        lastRefreshOrigin = origin
        lastRefreshDate = Date()
        let r = await RoutesService.results(for: destinations, from: origin, key: apiKey)
        results = r
        Shared.cachedResults = r
        loading = false
        WidgetCenter.shared.reloadAllTimelines()
    }
}
