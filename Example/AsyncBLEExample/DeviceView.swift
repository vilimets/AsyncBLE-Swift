// The device screen: connect, watch the state machine, and exercise a characteristic by UUID.
//
// The state list is the point. Walk away from the peripheral with this screen open and you
// should see `connected → reconnecting(1)`, then `connected` again when you walk back — with
// the notification stream still delivering, because a subscription is to a characteristic
// rather than to a link (PLAN.md §7 Q2). That is the manual smoke test.

import AsyncBLE
import CoreBluetooth
import SwiftUI

@MainActor
final class DeviceModel: ObservableObject {
    @Published private(set) var state: ConnectionState = .disconnected(reason: nil)
    @Published private(set) var transitions: [String] = []
    @Published private(set) var lastValue: String?
    @Published private(set) var notifications: [String] = []
    @Published private(set) var failure: String?
    @Published private(set) var isConnecting = false

    private let central: Central
    private let peripheralID: UUID
    private var connection: Connection?
    private var stateTask: Task<Void, Never>?
    private var notifyTask: Task<Void, Never>?

    init(central: Central, peripheralID: UUID) {
        self.central = central
        self.peripheralID = peripheralID
    }

    func connect() {
        guard connection == nil, !isConnecting else { return }
        isConnecting = true
        failure = nil
        Task {
            do {
                let connection = try await central.connect(peripheralID, timeout: .seconds(10))
                self.connection = connection
                isConnecting = false
                follow(connection)
            } catch {
                failure = String(describing: error)
                isConnecting = false
            }
        }
    }

    func disconnect() {
        Task { [connection] in
            await connection?.disconnect()
        }
    }

    /// Reads once. Fails fast if the link is down rather than queueing behind a reconnect.
    func read(_ uuid: CBUUID) {
        guard let connection else { return }
        failure = nil
        Task {
            do {
                let data = try await connection.read(uuid)
                lastValue = data.hexadecimal
            } catch {
                failure = String(describing: error)
            }
        }
    }

    /// Subscribes, and keeps the stream open across reconnects — the library re-establishes the
    /// subscription underneath us. The stream throws only if it cannot be restored.
    func subscribe(_ uuid: CBUUID) {
        guard let connection, notifyTask == nil else { return }
        failure = nil
        notifyTask = Task {
            do {
                for try await value in try await connection.notifications(for: uuid) {
                    notifications.insert(value.hexadecimal, at: 0)
                    notifications = Array(notifications.prefix(20))
                }
                note("notifications finished")
            } catch {
                failure = String(describing: error)
            }
            notifyTask = nil
        }
    }

    func unsubscribe() {
        notifyTask?.cancel()
        notifyTask = nil
    }

    private func follow(_ connection: Connection) {
        stateTask?.cancel()
        stateTask = Task {
            for await state in connection.states {
                self.state = state
                note(String(describing: state))
            }
            note("state stream finished — connection is over")
            self.connection = nil
        }
    }

    private func note(_ line: String) {
        transitions.insert("\(Date.now.formatted(date: .omitted, time: .standard))  \(line)", at: 0)
        transitions = Array(transitions.prefix(40))
    }
}

struct DeviceView: View {
    let central: Central
    let peripheralID: UUID
    let name: String?

    @StateObject private var model: DeviceModel
    @State private var characteristicText = ""

    init(central: Central, peripheralID: UUID, name: String?) {
        self.central = central
        self.peripheralID = peripheralID
        self.name = name
        _model = StateObject(wrappedValue: DeviceModel(central: central, peripheralID: peripheralID))
    }

    private var characteristic: CBUUID? {
        let trimmed = characteristicText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // CBUUID(string:) traps on malformed input, so validate the shape first.
        let isValid = trimmed.count == 4 || trimmed.count == 8 || trimmed.count == 36
        return isValid ? CBUUID(string: trimmed) : nil
    }

    var body: some View {
        List {
            Section("Link") {
                LabeledContent("State", value: String(describing: model.state))
                if let failure = model.failure {
                    Text(failure).font(.footnote).foregroundStyle(.red)
                }
                HStack {
                    Button("Connect", action: model.connect)
                        .disabled(model.state.isConnected || model.isConnecting)
                    Spacer()
                    Button("Disconnect", role: .destructive, action: model.disconnect)
                        .disabled(!model.state.isConnected)
                }
            }

            Section("Characteristic") {
                TextField("UUID — e.g. 2A37", text: $characteristicText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                HStack {
                    Button("Read") {
                        if let characteristic { model.read(characteristic) }
                    }
                    Spacer()
                    Button("Subscribe") {
                        if let characteristic { model.subscribe(characteristic) }
                    }
                    Spacer()
                    Button("Unsubscribe", action: model.unsubscribe)
                }
                .disabled(characteristic == nil || !model.state.isConnected)
                if let value = model.lastValue {
                    LabeledContent("Read", value: value).font(.footnote.monospaced())
                }
            }

            if !model.notifications.isEmpty {
                Section("Notifications") {
                    ForEach(Array(model.notifications.enumerated()), id: \.offset) { _, value in
                        Text(value).font(.footnote.monospaced())
                    }
                }
            }

            Section("State transitions") {
                ForEach(Array(model.transitions.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
        }
        .navigationTitle(name ?? "Device")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension Data {
    /// Hex, because a characteristic's bytes mean nothing to this app.
    var hexadecimal: String {
        isEmpty ? "(empty)" : map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
