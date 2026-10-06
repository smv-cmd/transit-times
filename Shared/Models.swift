import Foundation
import SwiftUI
import CoreLocation

enum Shared {
    static let groupID = "group.com.samvannette.transittimes"
    static var defaults: UserDefaults { UserDefaults(suiteName: groupID) ?? .standard }

    static var apiKey: String {
        get { defaults.string(forKey: "apiKey") ?? "" }
        set { defaults.set(newValue, forKey: "apiKey") }
    }

    static var destinations: [Destination] {
        get {
            guard let d = defaults.data(forKey: "destinations"),
                  let v = try? JSONDecoder().decode([Destination].self, from: d) else { return Destination.defaults }
            return v
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "destinations") }
    }

    static var lastLocation: CLLocationCoordinate2D? {
        get {
            guard defaults.object(forKey: "lat") != nil else { return nil }
            return .init(latitude: defaults.double(forKey: "lat"), longitude: defaults.double(forKey: "lon"))
        }
        set {
            guard let v = newValue else { return }
            defaults.set(v.latitude, forKey: "lat"); defaults.set(v.longitude, forKey: "lon")
        }
    }

    static var cachedResults: [UUID: TransitResult] {
        get {
            guard let d = defaults.data(forKey: "results"),
                  let v = try? JSONDecoder().decode([UUID: TransitResult].self, from: d) else { return [:] }
            return v
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "results") }
    }
}

struct Destination: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var address: String

    /// Placeholder presets (NYC) — edit them in the app via the gear icon.
    static let defaults: [Destination] = [
        .init(name: "Times Square", address: "Times Square Subway Station, New York, NY"),
        .init(name: "Grand Central", address: "Grand Central Terminal, New York, NY"),
        .init(name: "Brooklyn Bridge", address: "Brooklyn Bridge-City Hall Station, New York, NY"),
        .init(name: "Williamsburg", address: "Bedford Ave Station, Brooklyn, NY"),
        .init(name: "JFK Airport", address: "JFK Airport, Queens, NY"),
    ]
}

struct Line: Codable, Hashable {
    var name: String
    var colorHex: String?
}

struct TransitResult: Codable, Hashable {
    var minutes: Int?
    var lines: [Line] = []
    var boardStop: String?
    var headsign: String?
    var departures: [Date] = []
    var polyline: String?
    var lat: Double?
    var lon: Double?
    var error: String?
    var updated = Date()

    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lon else { return nil }
        return .init(latitude: lat, longitude: lon)
    }
}

extension Color {
    init(hex: String?, fallback: Color = .gray) {
        guard let s = hex?.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), s.count == 6,
              let v = UInt32(s, radix: 16) else { self = fallback; return }
        self.init(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
}

func decodePolyline(_ s: String) -> [CLLocationCoordinate2D] {
    var out: [CLLocationCoordinate2D] = []
    let bytes = Array(s.utf8)
    var i = 0, lat = 0, lon = 0
    func next() -> Int? {
        var result = 0, shift = 0
        while i < bytes.count {
            let b = Int(bytes[i]) - 63; i += 1
            result |= (b & 0x1f) << shift; shift += 5
            if b < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : result >> 1 }
        }
        return nil
    }
    while let dlat = next(), let dlon = next() {
        lat += dlat; lon += dlon
        out.append(.init(latitude: Double(lat) / 1e5, longitude: Double(lon) / 1e5))
    }
    return out
}
