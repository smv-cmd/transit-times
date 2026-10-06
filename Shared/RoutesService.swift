import Foundation
import CoreLocation

/// Google Routes API (successor to the Directions API), subway-only transit.
enum RoutesService {
    struct Parsed {
        var seconds: Int
        var lines: [Line]
        var boardStop: String?
        var headsign: String?
        var firstDeparture: Date?
        var polyline: String?
        var end: CLLocationCoordinate2D?
    }

    struct APIError: LocalizedError { let errorDescription: String? }

    private struct Response: Decodable {
        struct Route: Decodable { var duration: String?; var polyline: Poly?; var legs: [Leg]? }
        struct Poly: Decodable { var encodedPolyline: String? }
        struct Leg: Decodable { var steps: [Step]?; var endLocation: Loc? }
        struct Loc: Decodable { var latLng: LL? }
        struct LL: Decodable { var latitude: Double; var longitude: Double }
        struct Step: Decodable { var travelMode: String?; var transitDetails: TD? }
        struct TD: Decodable { var stopDetails: SD?; var transitLine: TL?; var headsign: String? }
        struct SD: Decodable { var departureStop: Stop?; var departureTime: String? }
        struct Stop: Decodable { var name: String? }
        struct TL: Decodable { var nameShort: String?; var name: String?; var color: String? }
        var routes: [Route]?
    }

    private struct ErrorBody: Decodable {
        struct E: Decodable { var message: String? }
        var error: E?
    }

    static func route(to dest: Destination, from origin: CLLocationCoordinate2D,
                      key: String, departAt: Date) async throws -> Parsed {
        var req = URLRequest(url: URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        if let id = Bundle.main.bundleIdentifier { req.setValue(id, forHTTPHeaderField: "X-Ios-Bundle-Identifier") }
        req.setValue("routes.duration,routes.polyline.encodedPolyline,routes.legs.endLocation,routes.legs.steps.travelMode,routes.legs.steps.transitDetails",
                     forHTTPHeaderField: "X-Goog-FieldMask")
        let when = max(departAt, Date().addingTimeInterval(10))
        let body: [String: Any] = [
            "origin": ["location": ["latLng": ["latitude": origin.latitude, "longitude": origin.longitude]]],
            "destination": ["address": dest.address],
            "travelMode": "TRANSIT",
            "departureTime": ISO8601DateFormatter().string(from: when),
            "transitPreferences": ["allowedTravelModes": ["SUBWAY"]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error?.message ?? "Request failed"
            throw APIError(errorDescription: msg)
        }
        let r = try JSONDecoder().decode(Response.self, from: data)
        guard let route = r.routes?.first else { throw APIError(errorDescription: "No subway route found") }

        let steps = (route.legs?.first?.steps ?? []).filter { $0.travelMode == "TRANSIT" }
        var lines: [Line] = []
        for s in steps {
            let l = Line(name: s.transitDetails?.transitLine?.nameShort ?? s.transitDetails?.transitLine?.name ?? "?",
                         colorHex: s.transitDetails?.transitLine?.color)
            if lines.last != l { lines.append(l) }
        }
        let first = steps.first?.transitDetails
        let end = route.legs?.last?.endLocation?.latLng
        return Parsed(
            seconds: Int((route.duration ?? "0s").dropLast()) ?? 0,
            lines: lines,
            boardStop: first?.stopDetails?.departureStop?.name,
            headsign: first?.headsign,
            firstDeparture: first?.stopDetails?.departureTime.flatMap(parseDate),
            polyline: route.polyline?.encodedPolyline,
            end: end.map { .init(latitude: $0.latitude, longitude: $0.longitude) })
    }

    static func result(for dest: Destination, from origin: CLLocationCoordinate2D, key: String) async -> TransitResult {
        do {
            let a = try await route(to: dest, from: origin, key: key, departAt: Date())
            var deps = a.firstDeparture.map { [$0] } ?? []
            // Second request just after the first train to get the following one.
            if let f = a.firstDeparture,
               let b = try? await route(to: dest, from: origin, key: key, departAt: f.addingTimeInterval(60)),
               let t = b.firstDeparture, t > f { deps.append(t) }
            return TransitResult(minutes: Int((Double(a.seconds) / 60).rounded()), lines: a.lines,
                                 boardStop: a.boardStop, headsign: a.headsign, departures: deps,
                                 polyline: a.polyline, lat: a.end?.latitude, lon: a.end?.longitude)
        } catch {
            return TransitResult(error: error.localizedDescription)
        }
    }

    static func results(for dests: [Destination], from origin: CLLocationCoordinate2D, key: String) async -> [UUID: TransitResult] {
        await withTaskGroup(of: (UUID, TransitResult).self) { group in
            for d in dests { group.addTask { (d.id, await result(for: d, from: origin, key: key)) } }
            var out: [UUID: TransitResult] = [:]
            for await (id, r) in group { out[id] = r }
            return out
        }
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
