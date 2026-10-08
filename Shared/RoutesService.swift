import Foundation
import CoreLocation

/// Google Routes API (successor to the Directions API), subway-only transit.
enum RoutesService {
    struct Parsed {
        var seconds: Int
        var walkSeconds = 0
        var staticSeconds: Int?
        var lines: [Line]
        var boardStop: String?
        var headsign: String?
        var firstDeparture: Date?
        var polyline: String?
        var end: CLLocationCoordinate2D?
    }

    struct APIError: LocalizedError { let errorDescription: String? }

    private struct Response: Decodable {
        struct Route: Decodable { var duration: String?; var staticDuration: String?; var polyline: Poly?; var legs: [Leg]? }
        struct Poly: Decodable { var encodedPolyline: String? }
        struct Leg: Decodable { var steps: [Step]?; var endLocation: Loc? }
        struct Loc: Decodable { var latLng: LL? }
        struct LL: Decodable { var latitude: Double; var longitude: Double }
        struct Step: Decodable { var travelMode: String?; var staticDuration: String?; var transitDetails: TD? }
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
                      key: String, departAt: Date, arriveBy: Date? = nil, mode: TravelMode = .train) async throws -> Parsed {
        var req = URLRequest(url: URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        if let id = Bundle.main.bundleIdentifier { req.setValue(id, forHTTPHeaderField: "X-Ios-Bundle-Identifier") }
        req.setValue("routes.duration,routes.staticDuration,routes.polyline.encodedPolyline,routes.legs.endLocation,routes.legs.steps.travelMode,routes.legs.steps.staticDuration,routes.legs.steps.transitDetails",
                     forHTTPHeaderField: "X-Goog-FieldMask")
        let when = max(departAt, Date().addingTimeInterval(10))
        var body: [String: Any] = [
            "origin": ["location": ["latLng": ["latitude": origin.latitude, "longitude": origin.longitude]]],
            "destination": ["address": dest.address],
        ]
        if let arriveBy, mode == .train {
            body["arrivalTime"] = ISO8601DateFormatter().string(from: arriveBy)
        } else {
            body["departureTime"] = ISO8601DateFormatter().string(from: when)
        }
        if mode == .train {
            body["travelMode"] = "TRANSIT"
            body["transitPreferences"] = ["allowedTravelModes": ["SUBWAY"]]
        } else {
            body["travelMode"] = "DRIVE"
            body["routingPreference"] = "TRAFFIC_AWARE"
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error?.message ?? "Request failed"
            throw APIError(errorDescription: msg)
        }
        let r = try JSONDecoder().decode(Response.self, from: data)
        guard let route = r.routes?.first else { throw APIError(errorDescription: mode == .train ? "No subway route found" : "No driving route found") }

        let steps = (route.legs?.first?.steps ?? []).filter { $0.travelMode == "TRANSIT" }
        var lines: [Line] = []
        for s in steps {
            let l = Line(name: s.transitDetails?.transitLine?.nameShort ?? s.transitDetails?.transitLine?.name ?? "?",
                         colorHex: s.transitDetails?.transitLine?.color)
            if lines.last != l { lines.append(l) }
        }
        let first = steps.first?.transitDetails
        var walk = 0
        for s in route.legs?.first?.steps ?? [] {
            if s.travelMode == "TRANSIT" { break }
            walk += Int((s.staticDuration ?? "0s").dropLast()) ?? 0
        }
        let end = route.legs?.last?.endLocation?.latLng
        return Parsed(
            seconds: Int((route.duration ?? "0s").dropLast()) ?? 0,
            walkSeconds: walk,
            staticSeconds: route.staticDuration.flatMap { Int($0.dropLast()) },
            lines: lines,
            boardStop: first?.stopDetails?.departureStop?.name,
            headsign: first?.headsign,
            firstDeparture: first?.stopDetails?.departureTime.flatMap(parseDate),
            polyline: route.polyline?.encodedPolyline,
            end: end.map { .init(latitude: $0.latitude, longitude: $0.longitude) })
    }

    static func result(for dest: Destination, from origin: CLLocationCoordinate2D, key: String, mta: [String: LineAlert] = [:]) async -> TransitResult {
        let mode = dest.mode
        do {
            var depart = Shared.departureDate()
            var arrive: Date?
            let a: Parsed
            var minutes: Int

            if let target = Shared.arrivalDate() {
                arrive = target
                if mode == .train {
                    a = try await route(to: dest, from: origin, key: key, departAt: target, arriveBy: target, mode: mode)
                    depart = a.firstDeparture.map { $0.addingTimeInterval(-Double(a.walkSeconds)) }
                        ?? target.addingTimeInterval(-Double(a.seconds))
                } else {
                    // Driving has no arrival-time support: estimate, then refine once.
                    let guess = try await route(to: dest, from: origin, key: key, departAt: target.addingTimeInterval(-1800), mode: mode)
                    a = try await route(to: dest, from: origin, key: key, departAt: target.addingTimeInterval(-Double(guess.seconds)), mode: mode)
                    depart = target.addingTimeInterval(-Double(a.seconds))
                }
                minutes = Int((target.timeIntervalSince(depart) / 60).rounded())
            } else {
                a = try await route(to: dest, from: origin, key: key, departAt: depart, mode: mode)
                minutes = Int((Double(a.seconds) / 60).rounded())
            }

            var deps = a.firstDeparture.map { [$0] } ?? []
            // Second request just after the first train to get the following one.
            if mode == .train, let f = a.firstDeparture,
               let b = try? await route(to: dest, from: origin, key: key, departAt: f.addingTimeInterval(60)),
               let t = b.firstDeparture, t > f { deps.append(t) }
            return TransitResult(minutes: minutes, lines: a.lines,
                                 boardStop: a.boardStop, headsign: a.headsign, departures: deps,
                                 trafficDelayMin: mode == .car ? a.staticSeconds.map { max(0, (a.seconds - $0) / 60) } : nil,
                                 departAt: depart, arriveBy: arrive,
                                 trafficRatio: mode == .car ? a.staticSeconds.flatMap { $0 > 0 ? Double(a.seconds) / Double($0) : nil } : nil,
                                 alerts: mode == .train ? MTAAlerts.match(lines: a.lines, in: mta) : [],
                                 polyline: a.polyline, lat: a.end?.latitude, lon: a.end?.longitude)
        } catch {
            return TransitResult(error: error.localizedDescription)
        }
    }

    static func results(for dests: [Destination], from origin: CLLocationCoordinate2D, key: String) async -> [UUID: TransitResult] {
        let mta = dests.contains { $0.mode == .train } ? await MTAAlerts.fetch(at: Shared.departureDate()) : [:]
        return await withTaskGroup(of: (UUID, TransitResult).self) { group in
            for d in dests { group.addTask { (d.id, await result(for: d, from: origin, key: key, mta: mta)) } }
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
