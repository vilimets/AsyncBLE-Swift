// A deliberately small SwiftUI app over AsyncBLE: scan, connect, watch the state machine,
// read and subscribe to a characteristic you name.
//
// It is generic on purpose. A demo hardcoded to one peripheral proves the library works with
// that peripheral; this one can be pointed at whatever hardware is on the desk, which is what
// makes it useful as the manual smoke test in PLAN.md §5.

import AsyncBLE
import CoreBluetooth
import SwiftUI

@main
struct AsyncBLEExampleApp: App {
    var body: some Scene {
        WindowGroup {
            ScanView()
        }
    }
}

/// Owns the one `Central` for the app's lifetime — creating a central is what prompts for
/// Bluetooth permission, so making a new one per screen would be user-hostile.
@MainActor
final class ScannerModel: ObservableObject {
    @Published private(set) var adapter: AdapterState = .unavailable(.unknown)
    @Published private(set) var discoveries: [Discovery] = []
    @Published private(set) var failure: String?
    @Published private(set) var isScanning = false

    let central = Central()

    private var adapterTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?

    /// Follows adapter availability for the banner. Never finishes while the central lives.
    func watchAdapter() {
        guard adapterTask == nil else { return }
        adapterTask = Task { [central] in
            for await state in central.adapterStates {
                adapter = state
            }
        }
    }

    /// Starts a scan. Cancelling the task stops the radio — no explicit stopScan needed.
    func startScanning() {
        guard scanTask == nil else { return }
        failure = nil
        isScanning = true
        scanTask = Task { [central] in
            do {
                for await discovery in try await central.scan() {
                    upsert(discovery)
                }
                // The stream finished: the adapter went away mid-scan.
                isScanning = false
                scanTask = nil
            } catch {
                failure = String(describing: error)
                isScanning = false
                scanTask = nil
            }
        }
    }

    func stopScanning() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    private func upsert(_ discovery: Discovery) {
        if let index = discoveries.firstIndex(where: { $0.peripheralID == discovery.peripheralID }) {
            discoveries[index] = discovery
        } else {
            discoveries.append(discovery)
            discoveries.sort { ($0.name ?? "\u{FFFF}") < ($1.name ?? "\u{FFFF}") }
        }
    }
}

struct ScanView: View {
    @StateObject private var model = ScannerModel()

    var body: some View {
        NavigationStack {
            List {
                if case .unavailable(let reason) = model.adapter {
                    Section {
                        Label("Bluetooth unavailable: \(String(describing: reason))", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if let failure = model.failure {
                    Section {
                        Text(failure).foregroundStyle(.red).font(.footnote)
                    }
                }
                Section("Discovered") {
                    if model.discoveries.isEmpty {
                        Text(model.isScanning ? "Scanning…" : "Not scanning")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.discoveries) { discovery in
                        NavigationLink(value: DeviceRoute(discovery: discovery)) {
                            DiscoveryRow(discovery: discovery)
                        }
                    }
                }
            }
            .navigationTitle("AsyncBLE")
            .navigationDestination(for: DeviceRoute.self) { route in
                DeviceView(central: model.central, peripheralID: route.peripheralID, name: route.name)
            }
            .toolbar {
                Button(model.isScanning ? "Stop" : "Scan") {
                    model.isScanning ? model.stopScanning() : model.startScanning()
                }
            }
        }
        .task {
            model.watchAdapter()
        }
    }
}

struct DiscoveryRow: View {
    let discovery: Discovery

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(discovery.name ?? "Unnamed")
                .font(.body)
            Text(discovery.peripheralID.uuidString)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            if let rssi = discovery.rssi {
                Text("\(rssi) dBm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// What the scan list navigates on.
///
/// A local type rather than a retroactive `Hashable` on `Discovery`: conforming another
/// module's type is the app's business to avoid, and a route only needs identity and a title.
struct DeviceRoute: Hashable {
    let peripheralID: UUID
    let name: String?

    init(discovery: Discovery) {
        peripheralID = discovery.peripheralID
        name = discovery.name
    }
}
