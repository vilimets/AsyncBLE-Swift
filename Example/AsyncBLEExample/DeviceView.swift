// The device screen: connect, watch the state machine, and exercise a characteristic by UUID.
//
// The state list is the point. Walk away from the peripheral with this screen open and you
// should see `connected → reconnecting(1)`, then `connected` again when you walk back — with
// the notification stream still delivering, because a subscription is to a characteristic
// rather than to a link. That is the manual smoke test.

import AsyncBLE
import SwiftUI
import UIKit

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
    private var subscribedUUID: CharacteristicID?

    init(central: Central, peripheralID: UUID) {
        self.central = central
        self.peripheralID = peripheralID
    }

    func connect() {
        guard connection == nil, !isConnecting else { return }
        isConnecting = true
        failure = nil
        note("connect: attempting")
        Task {
            do {
                let connection = try await central.connect(peripheralID, timeout: .seconds(10))
                self.connection = connection
                isConnecting = false
                note("connect: established")
                follow(connection)
            } catch {
                isConnecting = false
                fail("connect", error)
            }
        }
    }

    func disconnect() {
        note("disconnect: requested")
        Task { [connection] in
            await connection?.disconnect()
        }
    }

    /// Reads once. Fails fast if the link is down rather than queueing behind a reconnect.
    func read(_ uuid: CharacteristicID) {
        guard let connection else { return }
        failure = nil
        note("read(\(uuid.uuidString)): requesting")
        Task {
            do {
                let data = try await connection.read(uuid)
                lastValue = data.hexadecimal
                note("read(\(uuid.uuidString)): \(data.count) bytes")
            } catch {
                fail("read(\(uuid.uuidString))", error)
            }
        }
    }

    /// Subscribes, and keeps the stream open across reconnects — the library re-establishes the
    /// subscription underneath us. The stream throws only if it cannot be restored.
    ///
    /// Logged in three steps rather than one, on purpose: "requesting" vs. "confirmed" tells you
    /// whether the peripheral ever accepted the subscription, and the `cancelled` flag on the
    /// final line tells you whether the stream ended because *this app* tore it down (an
    /// `unsubscribe()` tap, or the view going away) rather than the library or peripheral.
    func subscribe(_ uuid: CharacteristicID) {
        guard let connection, notifyTask == nil else { return }
        failure = nil
        subscribedUUID = uuid
        note("subscribe(\(uuid.uuidString)): requesting")
        notifyTask = Task {
            do {
                let stream = try await connection.notifications(for: uuid)
                note("subscribe(\(uuid.uuidString)): confirmed, awaiting values")
                for try await value in stream {
                    let stamped = "\(Date.now.formatted(date: .omitted, time: .standard))  \(value.hexadecimal)"
                    notifications.insert(stamped, at: 0)
                    notifications = Array(notifications.prefix(20))
                }
                note("subscribe(\(uuid.uuidString)): stream finished, no error, cancelled=\(Task.isCancelled)")
            } catch {
                fail("subscribe(\(uuid.uuidString))", error)
            }
            notifyTask = nil
        }
    }

    func unsubscribe() {
        if let subscribedUUID {
            note("unsubscribe(\(subscribedUUID.uuidString)): requested")
        }
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

    /// Records a failure both where the UI's red banner reads it (`failure`) and in the
    /// timestamped `transitions` log, so a screenshot or a copied log shows *when* it happened
    /// relative to everything else rather than floating outside the timeline.
    private func fail(_ prefix: String, _ error: Error) {
        let message = String(describing: error)
        failure = message
        note("\(prefix): \(message)")
    }

    private func note(_ line: String) {
        let stamped = "\(Date.now.formatted(date: .omitted, time: .standard))  \(line)"
        transitions.insert(stamped, at: 0)
        transitions = Array(transitions.prefix(60))
    }
}

struct DeviceView: View {
    let central: Central
    let peripheralID: UUID
    let name: String?

    @StateObject private var model: DeviceModel
    @State private var characteristicText = ""
    @State private var copied = false

    init(central: Central, peripheralID: UUID, name: String?) {
        self.central = central
        self.peripheralID = peripheralID
        self.name = name
        _model = StateObject(wrappedValue: DeviceModel(central: central, peripheralID: peripheralID))
    }

    private var characteristic: CharacteristicID? {
        let trimmed = characteristicText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // CharacteristicID(string:) traps on malformed input, so validate fully before calling
        // it. Length alone is not enough — "ZZZZ" is four characters and still a crash.
        switch trimmed.count {
        case 4, 8:
            guard trimmed.allSatisfy(\.isHexDigit) else { return nil }
        case 36:
            guard UUID(uuidString: trimmed) != nil else { return nil }
        default:
            return nil
        }
        return CharacteristicID(string: trimmed)
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
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    UIPasteboard.general.string = logText
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy Log", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
        }
    }

    /// Everything on screen, oldest first, as plain text — meant to be pasted straight into a
    /// bug report or back to whoever is walking you through the smoke test.
    private var logText: String {
        var lines = [
            "AsyncBLE smoke test log — \(Date.now.formatted())",
            "Peripheral: \(name ?? "?") \(peripheralID.uuidString)",
            "State: \(String(describing: model.state))",
            "",
            "— Transitions (oldest first) —"
        ]
        lines.append(contentsOf: model.transitions.reversed())
        if !model.notifications.isEmpty {
            lines.append("")
            lines.append("— Notification values (oldest first) —")
            lines.append(contentsOf: model.notifications.reversed())
        }
        return lines.joined(separator: "\n")
    }
}

extension Data {
    /// Hex, because a characteristic's bytes mean nothing to this app.
    var hexadecimal: String {
        isEmpty ? "(empty)" : map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
