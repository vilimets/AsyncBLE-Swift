// The escape hatch: scoped access to `CBPeripheral` / `CBCentralManager`.
//
// Scoped rather than a property bag (PLAN.md §7 Q6): the closure runs on the library's queue,
// which is the only version where "this is safe to read" is actually true.

@preconcurrency import CoreBluetooth

extension Connection {
    /// Runs a closure with the CoreBluetooth objects behind this connection.
    ///
    /// This library does not cover all of CoreBluetooth, and an escape hatch is better than a
    /// fork. The closure runs on the library's own queue, which is what makes reading these
    /// objects safe — they are not thread-safe, so a plain property handing them out would be
    /// offering a data race with a reassuring doc comment.
    ///
    /// ```swift
    /// let mtu = await connection.withRaw { peripheral, _ in
    ///     peripheral.maximumWriteValueLength(for: .withoutResponse)
    /// }
    /// ```
    ///
    /// ## What this can and cannot do
    ///
    /// - **Synchronous inspection works.** Read properties, walk services and characteristics,
    ///   pull out values, log diagnostics.
    /// - **Callback-based operations do not.** `readRSSI()`, `readValue(for: descriptor)`, and
    ///   L2CAP channel opening all deliver their results to the peripheral's delegate — which
    ///   is this library's bridge, not you. The call will appear to succeed and the result will
    ///   be dropped. Those capabilities need real API support; open an issue and say what you
    ///   need (PLAN.md §2 corrects an earlier claim that this escape hatch covered them).
    /// - **Mutating connection state is undefined behavior.** `cancelPeripheralConnection`,
    ///   your own `connect`, or reassigning `delegate` puts the state machine and the radio out
    ///   of sync. Use ``Connection/disconnect()`` instead.
    ///
    /// - Parameter body: What to do with the peripheral and its central. The return type is
    ///   `Sendable`, which is what stops a `CBPeripheral` or `CBService` escaping the closure
    ///   into a context where touching it would race.
    /// - Returns: Whatever `body` returned.
    /// - Throws: Whatever `body` threw.
    public func withRaw<T: Sendable>(
        _ body: @Sendable (CBPeripheral, CBCentralManager) throws -> T
    ) async rethrows -> T {
        try core.withRawObjects(body)
    }
}
