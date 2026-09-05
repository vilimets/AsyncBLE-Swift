// A deliberately small SwiftUI app over AsyncBLE: scan, connect, watch the state machine,
// read and subscribe to a characteristic you name.
//
// It is generic on purpose. A demo hardcoded to one peripheral proves the library works with
// that peripheral; this one can be pointed at whatever hardware is on the desk, which is what
// makes it useful as the manual smoke test.
//
// It also opts into state restoration, because that is the one part of the library no automated
// test can reach: it needs a real device, a real termination and a real peripheral walking back
// into range. See Example/README.md for that walkthrough.

import AsyncBLE
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
    @Published private(set) var adapter: AdapterState = .unavailable(reason: .unknown)
    @Published private(set) var discoveries: [Discovery] = []
    @Published private(set) var failure: String?
    @Published private(set) var isScanning = false

    /// Links iOS handed back after relaunching the app in the background, newest last.
    @Published private(set) var restored: [UUID] = []

    /// Constant, and it has to be: the restore identifier is the key iOS files this central's
    /// state under, so a fresh one each launch would restore nothing, every launch, silently.
    static let restoreIdentifier = "com.asyncble.example.central"

    let central = Central(
        configuration: .init(restoreIdentifier: ScannerModel.restoreIdentifier)
    )

    private var adapterTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?

    /// Follows adapter availability for the banner. Never finishes while the central lives.
    func watchAdapter() {
        guard adapterTask == nil else { return }
        adapterTask = Task { [central] in
            for await state in central.adapterStates {
                adapter = state
            }
        }
    }

    /// Picks up the links that survived a background termination.
    ///
    /// The stream replays, so starting this from `.task` — long after restoration was actually
    /// delivered — misses nothing. That is the whole reason it is a stream.
    func watchRestoredConnections() {
        guard restoreTask == nil else { return }
        restoreTask = Task { [central] in
            for await connection in central.restoredConnections {
                restored.append(connection.peripheralID)
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
                if case .unavailable(reason: let reason) = model.adapter {
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
                if !model.restored.isEmpty {
                    Section("Restored after a relaunch") {
                        ForEach(model.restored, id: \.self) { peripheralID in
                            NavigationLink(value: DeviceRoute(peripheralID: peripheralID, name: nil)) {
                                Text(peripheralID.uuidString)
                                    .font(.caption2.monospaced())
                            }
                        }
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
            model.watchRestoredConnections()
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

    init(peripheralID: UUID, name: String?) {
        self.peripheralID = peripheralID
        self.name = name
    }

    init(discovery: Discovery) {
        self.init(peripheralID: discovery.peripheralID, name: discovery.name)
    }
}
