import Foundation

struct LineAlert: Codable, Hashable {
    enum Kind: Int, Codable { case change = 0, reduced = 1, delay = 2 }
    var line: String
    var kind: Kind
    var text: String

    var label: String {
        switch kind {
        case .delay: return "\(line) delays"
        case .reduced: return "\(line) reduced"
        case .change: return "\(line) changes"
        }
    }
}

/// MTA real-time subway service alerts (public GTFS-realtime JSON feed, no key needed).
enum MTAAlerts {
    static let url = URL(string: "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/camsys%2Fsubway-alerts.json")!

    /// Worst currently-active alert per route id (e.g. "A", "6", "6X").
    static func fetch(at when: Date = Date()) async -> [String: LineAlert] {
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entities = root["entity"] as? [[String: Any]] else { return [:] }
        let now = when.timeIntervalSince1970
        var out: [String: LineAlert] = [:]

        for e in entities {
            guard let a = e["alert"] as? [String: Any] else { continue }
            let periods = a["active_period"] as? [[String: Any]] ?? []
            let active = periods.isEmpty || periods.contains {
                let s = ($0["start"] as? Double) ?? 0
                let end = ($0["end"] as? Double) ?? .infinity
                return s <= now && now <= end
            }
            guard active else { continue }
            let type = ((a["transit_realtime.mercury_alert"] as? [String: Any])?["alert_type"] as? String) ?? ""
            guard let kind = kind(for: type) else { continue }
            let text = headline(a)
            let routes = Set((a["informed_entity"] as? [[String: Any]] ?? []).compactMap { $0["route_id"] as? String })
            for r in routes where (out[r]?.kind.rawValue ?? -1) < kind.rawValue {
                out[r] = LineAlert(line: r, kind: kind, text: text)
            }
        }
        return out
    }

    /// Alerts matching the lines used on a route (Google short name "6" also matches MTA "6X").
    static func match(lines: [Line], in all: [String: LineAlert]) -> [LineAlert] {
        var seen = Set<String>(), result: [LineAlert] = []
        for l in lines {
            for id in [l.name, l.name + "X"] {
                if let a = all[id], seen.insert(id).inserted { result.append(a) }
            }
        }
        return result.sorted { $0.kind.rawValue > $1.kind.rawValue }
    }

    private static func kind(for type: String) -> LineAlert.Kind? {
        let t = type.lowercased()
        if t.contains("delay") { return .delay }
        if t.contains("reduced") || t.contains("suspended") && !t.contains("planned") { return .reduced }
        if t.contains("planned - suspended") || t.contains("part suspended") || t.contains("reroute")
            || t.contains("detour") || t.contains("express to local") || t.contains("stops skipped") { return .change }
        return nil
    }

    private static func headline(_ a: [String: Any]) -> String {
        let tr = ((a["header_text"] as? [String: Any])?["translation"] as? [[String: Any]]) ?? []
        let s = (tr.first { ($0["language"] as? String) == "en" }?["text"] as? String) ?? ""
        return s.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
    }
}
