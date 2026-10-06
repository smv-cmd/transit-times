import SwiftUI
import MapKit
import CoreLocation
import WidgetKit

@main
struct TransitTimesApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: CLLocationCoordinate2D? = Shared.lastLocation
    private let mgr = CLLocationManager()

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters
        mgr.requestWhenInUseAuthorization()
        mgr.startUpdatingLocation()
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) {
        guard let c = l.last?.coordinate else { return }
        coordinate = c
        Shared.lastLocation = c
    }
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) { m.startUpdatingLocation() }
    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {}
}

@MainActor
final class TransitModel: ObservableObject {
    @Published var destinations = Shared.destinations { didSet { Shared.destinations = destinations } }
    @Published var results = Shared.cachedResults
    @Published var loading = false
    @Published var apiKey = Shared.apiKey { didSet { Shared.apiKey = apiKey } }

    func refresh(from origin: CLLocationCoordinate2D?) async {
        guard let origin, !apiKey.isEmpty else { return }
        loading = true
        let r = await RoutesService.results(for: destinations, from: origin, key: apiKey)
        results = r
        Shared.cachedResults = r
        loading = false
        WidgetCenter.shared.reloadAllTimelines()
    }
}
