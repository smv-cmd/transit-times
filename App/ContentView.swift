import SwiftUI
import MapKit

struct ContentView: View {
    @StateObject private var model = TransitModel()
    @StateObject private var location = LocationProvider()
    @State private var selected: UUID?
    @State private var showSettings = false
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                map.frame(height: 280)
                if model.apiKey.isEmpty {
                    ContentUnavailableView("Add your Google API key", systemImage: "key.fill",
                        description: Text("Tap the gear and paste a key with the Routes API enabled."))
                } else {
                    List(model.destinations) { d in
                        row(d)
                            .listRowBackground(selected == d.id ? Color.accentColor.opacity(0.12) : nil)
                            .contentShape(Rectangle())
                            .onTapGesture { selected = d.id }
                    }
                    .listStyle(.plain)
                    .refreshable { await model.refresh(from: location.coordinate) }
                }
            }
            .navigationTitle("Subway Times")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if model.loading { ProgressView() }
                    else { Button { Task { await model.refresh(from: location.coordinate) } } label: { Image(systemName: "arrow.clockwise") } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: { Task { await model.refresh(from: location.coordinate) } }) {
                SettingsView(model: model)
            }
            .task(id: location.coordinate == nil) { await model.refresh(from: location.coordinate) }
        }
    }

    private var map: some View {
        Map(position: $camera) {
            UserAnnotation()
            ForEach(model.destinations) { d in
                if let c = model.results[d.id]?.coordinate {
                    Marker(d.name, systemImage: "tram.fill", coordinate: c)
                        .tint(selected == d.id ? .red : .blue)
                }
            }
            if let s = selected, let p = model.results[s]?.polyline {
                MapPolyline(coordinates: decodePolyline(p)).stroke(.blue, lineWidth: 5)
            }
        }
        .onChange(of: selected) { _, s in
            guard let s, let r = model.results[s], let p = r.polyline else { return }
            let pts = decodePolyline(p)
            guard !pts.isEmpty else { return }
            let rect = pts.reduce(MKMapRect.null) { $0.union(MKMapRect(origin: MKMapPoint($1), size: .init(width: 0.1, height: 0.1))) }
            camera = .rect(rect.insetBy(dx: -rect.width * 0.2 - 500, dy: -rect.height * 0.2 - 500))
        }
    }

    private func row(_ d: Destination) -> some View {
        let r = model.results[d.id]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(d.name).font(.headline)
                Spacer()
                if let m = r?.minutes { Text("\(m) min").font(.title3.bold().monospacedDigit()) }
            }
            if let e = r?.error {
                Text(e).font(.caption).foregroundStyle(.red)
            } else if let r {
                HStack(spacing: 4) {
                    ForEach(Array(r.lines.enumerated()), id: \.offset) { _, l in LineBadge(line: l) }
                    if let h = r.headsign { Text("to \(h)").font(.caption).foregroundStyle(.secondary) }
                }
                if !r.departures.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                        Text("Next trains from \(r.boardStop ?? "station"):")
                        ForEach(r.departures, id: \.self) { Text($0, style: .time).bold() }
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Open in Google Maps", systemImage: "map") { openGoogleMaps(d) }
                .font(.caption).buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func openGoogleMaps(_ d: Destination) {
        let dest = d.address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var origin = ""
        if let c = location.coordinate { origin = "\(c.latitude),\(c.longitude)" }
        let app = URL(string: "comgooglemaps://?saddr=\(origin)&daddr=\(dest)&directionsmode=transit")!
        let web = URL(string: "https://www.google.com/maps/dir/?api=1&origin=\(origin)&destination=\(dest)&travelmode=transit")!
        UIApplication.shared.open(UIApplication.shared.canOpenURL(app) ? app : web)
    }
}

struct LineBadge: View {
    let line: Line
    var body: some View {
        Text(line.name)
            .font(.caption.bold()).foregroundStyle(.white)
            .frame(minWidth: 20).padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color(hex: line.colorHex), in: Capsule())
    }
}

struct SettingsView: View {
    @ObservedObject var model: TransitModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Google API key (Routes API enabled)") {
                    SecureField("API key", text: $model.apiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("5 preset destinations") {
                    ForEach($model.destinations) { $d in
                        VStack(alignment: .leading) {
                            TextField("Name", text: $d.name).font(.headline)
                            TextField("Address or place", text: $d.address)
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
