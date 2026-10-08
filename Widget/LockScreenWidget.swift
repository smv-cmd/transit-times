import WidgetKit
import SwiftUI
import AppIntents

struct LockDestinationsIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Destinations"
    static var description = IntentDescription("Choose up to 3 destinations. Leave blank to use your first three.")
    @Parameter(title: "First") var first: DestinationEntity?
    @Parameter(title: "Second") var second: DestinationEntity?
    @Parameter(title: "Third") var third: DestinationEntity?
}

struct LockProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, rows: Destination.defaults.prefix(3).map {
            Row(name: $0.name, mode: $0.mode, result: TransitResult(minutes: 25, lines: [Line(name: "A", colorHex: "#0039a6")], departures: [.now + 240]))
        })
    }

    func snapshot(for configuration: LockDestinationsIntent, in context: Context) async -> Entry { placeholder(in: context) }

    func timeline(for configuration: LockDestinationsIntent, in context: Context) async -> Timeline<Entry> {
        let all = Shared.destinations
        let picked = [configuration.first, configuration.second, configuration.third]
            .compactMap { e in all.first { $0.id.uuidString == e?.id } }
        var seen = Set<UUID>()
        let dests = (picked.isEmpty ? Array(all.prefix(3)) : picked).filter { seen.insert($0.id).inserted }
        return Timeline(entries: [await Provider.load(dests)], policy: .after(.now.addingTimeInterval(5 * 60)))
    }
}

/// Lock-screen-only widget (rectangular / inline / circular).
struct LockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "LockScreenWidget", intent: LockDestinationsIntent.self, provider: LockProvider()) { entry in
            WidgetView(entry: entry)
        }
        .configurationDisplayName("Lock Screen Times")
        .description("Travel times for up to 3 destinations on your Lock Screen.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}
