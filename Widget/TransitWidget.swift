import WidgetKit
import SwiftUI
import AppIntents
import CoreLocation

final class OneShotLocation: NSObject, CLLocationManagerDelegate {
    private let mgr = CLLocationManager()
    private var cont: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    @MainActor func get() async -> CLLocationCoordinate2D? {
        mgr.delegate = self
        guard mgr.isAuthorizedForWidgetUpdates else { return nil }
        return await withCheckedContinuation { c in
            cont = c
            mgr.requestLocation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.finish(nil) }
        }
    }
    private func finish(_ v: CLLocationCoordinate2D?) { cont?.resume(returning: v); cont = nil }
    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) { finish(l.last?.coordinate) }
    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) { finish(nil) }
}

struct Row: Hashable { var name: String; var mode: TravelMode; var result: TransitResult? }

struct Entry: TimelineEntry {
    var date: Date
    var rows: [Row]
    var message: String?
}

struct HomeDestinationsIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Destinations"
    static var description = IntentDescription("Choose which destinations to show, in order. Leave blank to show all.")
    @Parameter(title: "Destination 1") var d1: DestinationEntity?
    @Parameter(title: "Destination 2") var d2: DestinationEntity?
    @Parameter(title: "Destination 3") var d3: DestinationEntity?
    @Parameter(title: "Destination 4") var d4: DestinationEntity?
    @Parameter(title: "Destination 5") var d5: DestinationEntity?
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, rows: Destination.defaults.map {
            Row(name: $0.name, mode: $0.mode, result: TransitResult(minutes: 25, lines: [Line(name: "A", colorHex: "#0039a6")], departures: [.now + 240, .now + 600]))
        })
    }

    func snapshot(for configuration: HomeDestinationsIntent, in context: Context) async -> Entry { placeholder(in: context) }

    func timeline(for configuration: HomeDestinationsIntent, in context: Context) async -> Timeline<Entry> {
        let all = Shared.destinations
        let picked = [configuration.d1, configuration.d2, configuration.d3, configuration.d4, configuration.d5]
            .compactMap { e in all.first { $0.id.uuidString == e?.id } }
        var seen = Set<UUID>()
        let dests = (picked.isEmpty ? all : picked).filter { seen.insert($0.id).inserted }
        return Timeline(entries: [await Self.load(dests)], policy: .after(.now.addingTimeInterval(5 * 60)))
    }

    static func load(_ dests: [Destination]) async -> Entry {
        let key = Shared.apiKey
        var entry = Entry(date: .now, rows: dests.map { Row(name: $0.name, mode: $0.mode) })
        if key.isEmpty {
            entry.message = "Open the app and add your API key"
            return entry
        }
        let fresh = await OneShotLocation().get()
        if let fresh { Shared.lastLocation = fresh }
        guard let origin = fresh ?? Shared.lastLocation else {
            entry.message = "Open the app once to share your location"
            return entry
        }
        let r = await RoutesService.results(for: dests, from: origin, key: key)
        entry.rows = dests.map { Row(name: $0.name, mode: $0.mode, result: r[$0.id]) }
        return entry
    }
}

struct WidgetView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family
    private var large: Bool { family == .systemLarge }

    var body: some View {
        switch family {
        case .accessoryRectangular: lockRectangular
        case .accessoryInline: lockInline
        case .accessoryCircular: lockCircular
        default: homeBody
        }
    }

    // MARK: Lock screen

    private func shortName(_ s: String) -> String { String(s.prefix(10)) }

    private var lockRectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let m = entry.message {
                Text(m).font(.caption2)
            } else {
                ForEach(Array(entry.rows.prefix(3).enumerated()), id: \.offset) { _, r in
                    HStack(spacing: 3) {
                        Image(systemName: r.mode.icon).font(.system(size: 9))
                        Text(shortName(r.name)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 2)
                        if alert(r) != nil, !(r.mode == .car && r.result?.traffic == .clear) { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)) }
                        if r.mode == .train, let l = r.result?.lines.first { Text(l.name).font(.system(size: 10, weight: .heavy)).padding(.horizontal, 3).overlay(Capsule().stroke(lineWidth: 1)) }
                        if let res = r.result, res.arriveBy != nil {
                            Text(Self.timeFmt.string(from: res.departAt) + "→").font(.system(size: 10).monospacedDigit())
                        }
                        Text(r.result?.minutes.map { "\($0)m" } ?? "—").font(.system(size: 13, weight: .bold).monospacedDigit())
                    }
                }
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    private var lockInline: some View {
        let parts = entry.rows.prefix(2).map { r in "\(shortName(r.name)) \(r.result?.minutes.map { "\($0)m" } ?? "—")" }
        return Label(parts.joined(separator: " · "), systemImage: entry.rows.first?.mode.icon ?? "tram.fill")
            .containerBackground(for: .widget) { Color.clear }
    }

    private var lockCircular: some View {
        let r = entry.rows.first
        return VStack(spacing: 0) {
            Image(systemName: r?.mode.icon ?? "tram.fill").font(.system(size: 11))
            Text(r?.result?.minutes.map { "\($0)" } ?? "—").font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
            Text("min").font(.system(size: 8))
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    // MARK: Home screen

    private var homeBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if large {
                HStack {
                    Text("Travel times").font(.footnote.bold()).foregroundStyle(.secondary)
                    Spacer()
                    if let r = entry.rows.compactMap({ $0.result }).first(where: { $0.arriveBy != nil }), let arrive = r.arriveBy {
                        Text("Arrive by " + Self.timeFmt.string(from: arrive) + (Calendar.current.component(.hour, from: arrive) >= 12 ? " PM" : " AM"))
                            .font(.footnote.bold()).foregroundStyle(.secondary)
                    } else if let d = entry.rows.compactMap({ $0.result?.departAt }).first, d.timeIntervalSince(entry.date) > 300 {
                        Text("Leaving " + Self.timeFmt.string(from: d) + (Calendar.current.component(.hour, from: d) >= 12 ? " PM" : " AM"))
                            .font(.footnote.bold()).foregroundStyle(.secondary)
                    } else {
                        Text(entry.date, style: .time).font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(.bottom, 6)
            }
            if let m = entry.message {
                Spacer(); Text(m).font(.callout).multilineTextAlignment(.center).frame(maxWidth: .infinity); Spacer()
            } else {
                ForEach(Array(entry.rows.enumerated()), id: \.offset) { i, r in
                    if i > 0 { Divider().opacity(0.4) }
                    Spacer(minLength: 0)
                    rowView(r)
                    Spacer(minLength: 0)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func nextDeps(_ res: TransitResult) -> [Date] {
        Array(res.departures.filter { $0 > max(res.departAt, entry.date) }.prefix(2))
    }

    /// Delay-style badge: traffic for cars, long wait for trains.
    private func alert(_ r: Row) -> (text: String, color: Color)? {
        guard let res = r.result, res.error == nil else { return nil }
        if r.mode == .train, let top = res.alerts.first {
            return (top.label, top.kind == .delay ? .red : top.kind == .reduced ? .orange : .yellow.opacity(0.9))
        }
        if r.mode == .car, let t = res.trafficText { return (t, res.trafficColor) }
        if r.mode == .train, let next = nextDeps(res).first {
            let wait = Int(next.timeIntervalSince(max(res.departAt, entry.date)) / 60)
            if wait >= 15 { return ("\(wait) min wait", .red) }
            if wait >= 8 { return ("\(wait) min wait", .orange) }
        }
        return nil
    }

    private func badge(_ text: String, _ color: Color, size: CGFloat) -> some View {
        Text(text).font(.system(size: size, weight: .bold)).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color, in: Capsule())
    }

    private func lineBadges(_ res: TransitResult) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(res.lines.prefix(4).enumerated()), id: \.offset) { _, l in
                Text(l.name).font(.system(size: large ? 14 : 13, weight: .heavy)).foregroundStyle(.white)
                    .frame(minWidth: large ? 22 : 20, minHeight: large ? 22 : 20)
                    .background(Color(hex: l.colorHex), in: Circle())
            }
        }
    }

    private func rowView(_ r: Row) -> some View {
        let res = r.result
        let alertInfo = alert(r)
        let times = res.map(nextDeps) ?? []
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: r.mode.icon).font(.system(size: large ? 14 : 12)).foregroundStyle(.secondary)
                    Text(r.name).font(.system(size: large ? 18 : 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                }
                if large, let res, res.error == nil {
                    HStack(spacing: 6) {
                        if res.arriveBy != nil {
                            Text("Leave " + Self.timeFmt.string(from: res.departAt)).font(.system(size: 14, weight: .bold).monospacedDigit())
                        }
                        if r.mode == .train { lineBadges(res) }
                        if r.mode == .train, !times.isEmpty {
                            Text(times.map { Self.timeFmt.string(from: $0) }.joined(separator: " · "))
                                .font(.system(size: 14, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if let a = alertInfo, r.mode != .car { badge(a.text, a.color, size: 12) }
                    }
                }
            }
            Spacer(minLength: 4)
            if let e = res?.error {
                Text("No route").font(.footnote).foregroundStyle(.red).help(e)
            } else if let res {
                if !large {
                    if r.mode == .train { lineBadges(res) }
                    if let a = alertInfo {
                        if r.mode == .car { Circle().fill(a.color).frame(width: 11, height: 11) }
                        else { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(a.color) }
                    }
                }
                if let m = res.minutes {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(m)").font(.system(size: large ? 30 : 22, weight: .bold, design: .rounded).monospacedDigit())
                        Text("min").font(.system(size: large ? 13 : 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .overlay {
            // Traffic indicator for car rows, centered in large widgets.
            if large, r.mode == .car, let a = alertInfo { badge(a.text, a.color, size: 14) }
        }
    }

    static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm"; return f
    }()
}

struct TransitWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "TransitWidget", intent: HomeDestinationsIntent.self, provider: Provider()) { entry in
            WidgetView(entry: entry)
        }
        .configurationDisplayName("Subway Times")
        .description("Travel times and next trains. Press and hold to choose destinations.")
        .supportedFamilies([.systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

@main
struct TransitWidgetBundle: WidgetBundle {
    var body: some Widget { TransitWidget(); SingleDestinationWidget(); LockScreenWidget() }
}
