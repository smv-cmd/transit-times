import WidgetKit
import SwiftUI
import AppIntents
import CoreLocation

struct DestinationEntity: AppEntity {
    var id: String
    var name: String
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Destination"
    static var defaultQuery = DestinationQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct DestinationQuery: EntityQuery {
    private var all: [DestinationEntity] { Shared.destinations.map { .init(id: $0.id.uuidString, name: $0.name) } }
    func entities(for identifiers: [String]) async throws -> [DestinationEntity] { all.filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [DestinationEntity] { all }
    func defaultResult() async -> DestinationEntity? { all.first }
}

struct SelectDestinationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Destination"
    static var description = IntentDescription("Choose which destination to show.")
    @Parameter(title: "Destination") var destination: DestinationEntity?
}

struct SingleEntry: TimelineEntry {
    var date: Date
    var row: Row?
    var message: String?
}

struct SingleProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SingleEntry {
        SingleEntry(date: .now, row: Row(name: "Times Square", mode: .train,
            result: TransitResult(minutes: 24, lines: [Line(name: "A", colorHex: "#0039a6")], departures: [.now + 240, .now + 600])))
    }

    func snapshot(for configuration: SelectDestinationIntent, in context: Context) async -> SingleEntry {
        placeholder(in: context)
    }

    func timeline(for configuration: SelectDestinationIntent, in context: Context) async -> Timeline<SingleEntry> {
        let dests = Shared.destinations
        let chosen = dests.first { $0.id.uuidString == configuration.destination?.id } ?? dests.first
        var entry = SingleEntry(date: .now, row: chosen.map { Row(name: $0.name, mode: $0.mode) })
        let key = Shared.apiKey
        if key.isEmpty {
            entry.message = "Add your API key in the app"
        } else if let d = chosen {
            let fresh = await OneShotLocation().get()
            if let fresh { Shared.lastLocation = fresh }
            if let origin = fresh ?? Shared.lastLocation {
                let mta = d.mode == .train ? await MTAAlerts.fetch(at: Shared.departureDate()) : [:]
                let r = await RoutesService.result(for: d, from: origin, key: key, mta: mta)
                entry.row = Row(name: d.name, mode: d.mode, result: r)
            } else {
                entry.message = "Open the app once for location"
            }
        }
        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(5 * 60)))
    }
}

struct SingleWidgetView: View {
    let entry: SingleEntry
    @Environment(\.widgetFamily) private var family

    private var res: TransitResult? { entry.row?.result }
    private var mode: TravelMode { entry.row?.mode ?? .train }
    private var minutesText: String { res?.minutes.map { "\($0)" } ?? "—" }
    private var ref: Date { max(res?.departAt ?? entry.date, entry.date) }
    private var next: [Date] { Array((res?.departures ?? []).filter { $0 > ref }.prefix(2)) }

    private var alert: (text: String, color: Color)? {
        guard let res, res.error == nil else { return nil }
        if mode == .train, let top = res.alerts.first {
            return (top.label, top.kind == .delay ? .red : top.kind == .reduced ? .orange : .yellow)
        }
        if mode == .car, let t = res.trafficText { return (t, res.trafficColor) }
        if mode == .train, let n = next.first {
            let w = Int(n.timeIntervalSince(ref) / 60)
            if w >= 8 { return ("\(w) min wait", w >= 15 ? .red : .orange) }
        }
        return nil
    }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        default: small
        }
    }

    private var lines: some View {
        HStack(spacing: 3) {
            ForEach(Array((res?.lines ?? []).prefix(4).enumerated()), id: \.offset) { _, l in
                Text(l.name).font(.system(size: 14, weight: .heavy)).foregroundStyle(.white)
                    .frame(minWidth: 22, minHeight: 22).background(Color(hex: l.colorHex), in: Circle())
            }
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: mode.icon).font(.footnote).foregroundStyle(.secondary)
                Text(entry.row?.name ?? "No destination").font(.headline).lineLimit(1).minimumScaleFactor(0.8)
            }
            if let m = entry.message {
                Spacer(); Text(m).font(.footnote); Spacer()
            } else if let e = res?.error {
                Spacer(); Text(e).font(.caption).foregroundStyle(.red).lineLimit(4); Spacer()
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(minutesText).font(.system(size: 46, weight: .bold, design: .rounded).monospacedDigit())
                    Text("min").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                }
                if mode == .train {
                    lines
                    if !next.isEmpty {
                        Text("Next " + next.map { Self.fmt.string(from: $0) }.joined(separator: " · "))
                            .font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if let res, let arrive = res.arriveBy {
                    Text("Leave by " + Self.fmt.string(from: res.departAt) + " · arrive " + Self.fmt.string(from: arrive))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).lineLimit(2)
                } else if let res, res.departAt.timeIntervalSince(entry.date) > 300 {
                    Text("Leave " + Self.fmt.string(from: res.departAt)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
                if let a = alert {
                    Text(a.text).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(a.color, in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: mode.icon).font(.system(size: 10))
                Text(entry.row?.name ?? "—").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if alert != nil { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(minutesText).font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                Text("min").font(.system(size: 12))
                Spacer(minLength: 0)
                if mode == .train, let l = res?.lines.first { Text(l.name).font(.system(size: 13, weight: .heavy)).padding(.horizontal, 5).overlay(Capsule().stroke(lineWidth: 1.5)) }
            }
            if mode == .train, !next.isEmpty {
                Text("Next " + next.map { Self.fmt.string(from: $0) }.joined(separator: " · ")).font(.system(size: 11).monospacedDigit())
            } else if let a = alert { Text(a.text).font(.system(size: 11)) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { Color.clear }
    }

    private var circular: some View {
        VStack(spacing: 0) {
            Image(systemName: mode.icon).font(.system(size: 11))
            Text(minutesText).font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
            Text("min").font(.system(size: 8))
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm"; return f }()
}

struct SingleDestinationWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "SingleDestinationWidget", intent: SelectDestinationIntent.self, provider: SingleProvider()) { entry in
            SingleWidgetView(entry: entry)
        }
        .configurationDisplayName("One Destination")
        .description("Travel time, next trains and alerts for one place. Press and hold to choose which.")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryCircular])
    }
}
