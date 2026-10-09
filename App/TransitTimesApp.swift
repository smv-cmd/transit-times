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
    #if DEBUG
    /// `-demo` launch argument: fills sample data so App Store screenshots can be captured without a Google key.
    init() {
        guard ProcessInfo.processInfo.arguments.contains("-demo") else { return }
        let d = Destination.defaults
        apiKey = "demo"
        let now = Date()
        func r(_ m: Int, _ lines: [Line], _ lat: Double, _ lon: Double, deps: [Int] = [], alerts: [LineAlert] = []) -> TransitResult {
            TransitResult(minutes: m, lines: lines, boardStop: "Nearest station", headsign: "Downtown",
                          departures: deps.map { now.addingTimeInterval(Double($0) * 60) }, alerts: alerts, lat: lat, lon: lon)
        }
        func ln(_ n: String, _ c: String) -> Line { Line(name: n, colorHex: c) }
        results = [
            d[0].id: r(24, [ln("A", "#0039a6"), ln("C", "#0039a6")], 40.7580, -73.9855, deps: [3, 9]),
            d[1].id: r(18, [ln("4", "#00933c"), ln("5", "#00933c")], 40.7527, -73.9772, deps: [5, 11],
                       alerts: [LineAlert(line: "4", kind: .delay, text: "Southbound 4 trains are running with delays.")]),
            d[2].id: r(31, [ln("J", "#996633")], 40.7132, -74.0041, deps: [12, 20]),
            d[3].id: r(27, [ln("L", "#a7a9ac")], 40.7177, -73.9573, deps: [2, 8]),
            d[4].id: { var x = r(58, [], 40.6413, -73.7781); x.trafficRatio = 1.35; x.trafficDelayMin = 15; return x }(),
        ]
    }
    #endif

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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-demo") { return }
        #endif
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
