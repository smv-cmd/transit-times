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

    /// "Leave at" time of day, as minutes after midnight. nil = leave now.
    static var leaveMinutes: Int? {
        get { defaults.object(forKey: "leaveMin") as? Int }
        set { if let v = newValue { defaults.set(v, forKey: "leaveMin") } else { defaults.removeObject(forKey: "leaveMin") } }
    }

    /// "Arrive by" time of day, as minutes after midnight. Overrides leave-at when set.
    static var arriveMinutes: Int? {
        get { defaults.object(forKey: "arriveMin") as? Int }
        set { if let v = newValue { defaults.set(v, forKey: "arriveMin") } else { defaults.removeObject(forKey: "arriveMin") } }
    }

    static func arrivalDate() -> Date? {
        guard let m = arriveMinutes else { return nil }
        let cal = Calendar.current
        let d = cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
        return d > Date().addingTimeInterval(300) ? d : cal.date(byAdding: .day, value: 1, to: d) ?? d
    }

    /// Next occurrence of the chosen leave time (today if still ahead, else tomorrow), or now.
    static func departureDate() -> Date {
        if let a = arrivalDate() { return max(Date(), a.addingTimeInterval(-1800)) }  // rough reference (alerts)
        guard let m = leaveMinutes else { return Date() }
        let cal = Calendar.current
        let d = cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
        return d > Date() ? d : cal.date(byAdding: .day, value: 1, to: d) ?? d
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

enum TravelMode: String, Codable, CaseIterable {
    case train, car
    var label: String { self == .train ? "Train" : "Car" }
    var icon: String { self == .train ? "tram.fill" : "car.fill" }
}

struct Destination: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var address: String
    var mode: TravelMode = .train

    init(id: UUID = UUID(), name: String, address: String, mode: TravelMode = .train) {
        self.id = id; self.name = name; self.address = address; self.mode = mode
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        address = try c.decode(String.self, forKey: .address)
        mode = (try? c.decode(TravelMode.self, forKey: .mode)) ?? .train
    }

    /// Placeholder presets (NYC) — edit them in the app via the gear icon.
    static let defaults: [Destination] = [
        .init(name: "Times Square", address: "Times Square Subway Station, New York, NY"),
        .init(name: "Grand Central", address: "Grand Central Terminal, New York, NY"),
        .init(name: "Brooklyn Bridge", address: "Brooklyn Bridge-City Hall Station, New York, NY"),
        .init(name: "Williamsburg", address: "Bedford Ave Station, Brooklyn, NY"),
        .init(name: "JFK Airport", address: "JFK Airport, Queens, NY", mode: .car),
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
    var trafficDelayMin: Int?
    var departAt = Date()
    var arriveBy: Date?
    var trafficRatio: Double?
    var alerts: [LineAlert] = []
    var polyline: String?
    var lat: Double?
    var lon: Double?
    var error: String?
    var updated = Date()

    enum Traffic { case clear, moderate, heavy }

    /// Live-traffic condition for driving results (duration vs. no-traffic duration).
    var traffic: Traffic? {
        guard let r = trafficRatio else { return nil }
        return r < 1.1 ? .clear : r < 1.3 ? .moderate : .heavy
    }

    var trafficText: String? {
        guard let t = traffic else { return nil }
        let d = trafficDelayMin ?? 0
        switch t {
        case .clear: return "Light traffic"
        case .moderate: return "Moderate +\(d)m"
        case .heavy: return "Heavy +\(d)m"
        }
    }

    var trafficColor: Color {
        switch traffic { case .heavy: .red; case .moderate: .orange; default: .green }
    }

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
