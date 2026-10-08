import SwiftUI
import MapKit

struct ContentView: View {
    @StateObject private var model = TransitModel()
    @ObservedObject private var location = LocationProvider.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var selected: UUID?
    @State private var showSettings = false
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                map.frame(height: 280)
                leaveBar
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
            .onChange(of: location.coordinate?.latitude) { _, _ in Task { await model.refreshIfNeeded(from: location.coordinate) } }
            .onChange(of: scenePhase) { _, p in if p == .active { Task { await model.refreshIfNeeded(from: location.coordinate) } } }
            .task { await model.refreshIfNeeded(from: location.coordinate) }
            .task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)); await model.refreshIfNeeded(from: location.coordinate) } }
        }
    }

    private var map: some View {
        Map(position: $camera) {
            UserAnnotation()
            ForEach(model.destinations) { d in
                if let c = model.results[d.id]?.coordinate {
                    Marker(d.name, systemImage: d.mode.icon, coordinate: c)
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
                Picker("Mode", selection: modeBinding(d)) {
                    ForEach(TravelMode.allCases, id: \.self) { Image(systemName: $0.icon).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 90)
                Spacer()
                if let m = r?.minutes { Text("\(m) min").font(.title3.bold().monospacedDigit()) }
            }
            if let arrive = r?.arriveBy, let leave = r?.departAt, r?.error == nil {
                Label("Leave by \(leave.formatted(date: .omitted, time: .shortened)) → arrive \(arrive.formatted(date: .omitted, time: .shortened))", systemImage: "figure.walk.departure")
                    .font(.caption.bold()).foregroundStyle(leave < Date() ? .red : .primary)
            }
            if let e = r?.error {
                Text(e).font(.caption).foregroundStyle(.red)
            } else if let r {
                HStack(spacing: 4) {
                    if d.mode == .car { Image(systemName: "car.fill").font(.caption).foregroundStyle(.secondary); Text(r.trafficText ?? "with traffic").font(.caption.bold()).foregroundStyle(r.trafficText == nil ? .secondary : r.trafficColor) }
                    ForEach(Array(r.lines.enumerated()), id: \.offset) { _, l in LineBadge(line: l) }
                    if let h = r.headsign { Text("to \(h)").font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(r.alerts, id: \.self) { a in
                    Label(a.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).lineLimit(3)
                        .foregroundStyle(a.kind == .delay ? .red : a.kind == .reduced ? .orange : .yellow)
                }
                if d.mode == .train, !r.departures.isEmpty {
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

    private var leaveBar: some View {
        HStack {
            Picker("Timing", selection: Binding(
                get: { model.arriveMinutes != nil ? 2 : model.leaveMinutes != nil ? 1 : 0 },
                set: { v in
                    let c = Calendar.current.dateComponents([.hour, .minute], from: Date().addingTimeInterval(v == 2 ? 3600 : 1800))
                    let m = (c.hour ?? 8) * 60 + (c.minute ?? 0)
                    model.leaveMinutes = v == 1 ? m : nil
                    model.arriveMinutes = v == 2 ? m : nil
                })) {
                Text("Leave now").tag(0)
                Text("Leave at").tag(1)
                Text("Arrive by").tag(2)
            }.pickerStyle(.segmented)
            if model.leaveMinutes != nil || model.arriveMinutes != nil {
                DatePicker("", selection: Binding(
                    get: { (model.arriveMinutes != nil ? Shared.arrivalDate() : nil) ?? Shared.departureDate() },
                    set: { d in
                        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                        if model.arriveMinutes != nil { model.arriveMinutes = m } else { model.leaveMinutes = m }
                    }), displayedComponents: .hourAndMinute).labelsHidden()
            }
        }
        .padding(.horizontal).padding(.vertical, 6)
        .onChange(of: model.leaveMinutes) { _, _ in Task { await model.refresh(from: location.coordinate) } }
        .onChange(of: model.arriveMinutes) { _, _ in Task { await model.refresh(from: location.coordinate) } }
    }

    private func modeBinding(_ d: Destination) -> Binding<TravelMode> {
        Binding(get: { d.mode }, set: { new in
            guard let i = model.destinations.firstIndex(where: { $0.id == d.id }) else { return }
            model.destinations[i].mode = new
            model.results[d.id] = nil
            Task { await model.refresh(from: location.coordinate) }
        })
    }

    private func openGoogleMaps(_ d: Destination) {
        let dest = d.address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var origin = ""
        if let c = location.coordinate { origin = "\(c.latitude),\(c.longitude)" }
        let app = URL(string: "comgooglemaps://?saddr=\(origin)&daddr=\(dest)&directionsmode=\(d.mode == .car ? "driving" : "transit")")!
        let web = URL(string: "https://www.google.com/maps/dir/?api=1&origin=\(origin)&destination=\(dest)&travelmode=\(d.mode == .car ? "driving" : "transit")")!
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
                            Picker("Mode", selection: $d.mode) {
                                ForEach(TravelMode.allCases, id: \.self) { Label($0.label, systemImage: $0.icon).tag($0) }
                            }.pickerStyle(.segmented)
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
