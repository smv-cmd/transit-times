import WidgetKit
import SwiftUI

struct Row: Hashable { var name: String; var result: TransitResult? }

struct Entry: TimelineEntry {
    var date: Date
    var rows: [Row]
    var message: String?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, rows: Destination.defaults.map {
            Row(name: $0.name, result: TransitResult(minutes: 25, lines: [Line(name: "A", colorHex: "#0039a6")], departures: [.now + 240, .now + 600]))
        })
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        Task {
            let dests = Shared.destinations
            let key = Shared.apiKey
            var entry = Entry(date: .now, rows: dests.map { Row(name: $0.name) })
            if key.isEmpty {
                entry.message = "Open the app and add your API key"
            } else if let origin = Shared.lastLocation {
                let r = await RoutesService.results(for: dests, from: origin, key: key)
                entry.rows = dests.map { Row(name: $0.name, result: r[$0.id]) }
                Shared.cachedResults = r
            } else {
                entry.message = "Open the app once to share your location"
            }
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(5 * 60))))
        }
    }
}

struct WidgetView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 4) {
            HStack {
                Label("Subway", systemImage: "tram.fill").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Text(entry.date, style: .time).font(.caption2).foregroundStyle(.secondary)
            }
            if let m = entry.message {
                Spacer(); Text(m).font(.footnote).frame(maxWidth: .infinity); Spacer()
            } else {
                ForEach(entry.rows, id: \.self) { rowView($0) }
            }
        }
    }

    private func rowView(_ r: Row) -> some View {
        HStack(spacing: 6) {
            Text(r.name).font(family == .systemLarge ? .subheadline.bold() : .caption.bold()).lineLimit(1)
            Spacer(minLength: 4)
            if let e = r.result?.error {
                Text(e).font(.caption2).foregroundStyle(.red).lineLimit(1)
            } else if let res = r.result {
                ForEach(Array(res.lines.prefix(3).enumerated()), id: \.offset) { _, l in
                    Text(l.name).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(minWidth: 16).padding(.horizontal, 2)
                        .background(Color(hex: l.colorHex), in: Capsule())
                }
                let next = res.departures.filter { $0 > entry.date }.prefix(2)
                if !next.isEmpty {
                    Text(next.map { Self.timeFmt.string(from: $0) }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                if let m = res.minutes { Text("\(m)m").font(.subheadline.bold().monospacedDigit()).frame(minWidth: 34, alignment: .trailing) }
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }

    static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm"; return f
    }()
}

struct TransitWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TransitWidget", provider: Provider()) { entry in
            WidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Subway Times")
        .description("Travel time and next trains to your 5 destinations.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

@main
struct TransitWidgetBundle: WidgetBundle {
    var body: some Widget { TransitWidget() }
}
