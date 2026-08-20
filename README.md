# AsyncBLE

A modern Swift wrapper over CoreBluetooth (central role) with three first-class features:

1. **Explicit connection state machine** — observable, testable, single source of truth
2. **Reconnection you can reason about** — CoreBluetooth already retries a pending connect
   indefinitely. What it never does is tell you what is happening, or give up. This library
   does both, and skips the retry loop everyone writes by hand.
3. **async/await API** — no delegates, no CoreBluetooth types in public signatures

Target audience: iOS developers integrating BLE devices.

**Platforms:** iOS 16+, Swift 5.9+, Swift Package Manager only.

## In scope (0.1.0)

- Central role only
- Scanning: `AsyncStream<Discovery>`, service UUID filter, allow-duplicates option
- `connect(_:timeout:) async throws -> Connection` with configurable timeout (CoreBluetooth has no native connect timeout)
- `connectWhenAvailable(_:)` — a pending connect with no deadline, for resuming a known device at launch
- Connection state machine, observable via `AsyncStream<ConnectionState>`
  - States: `disconnected`, `connecting`, `connected`, `reconnecting(attempt:)`
- Adapter availability observable via `AsyncStream<AdapterState>`
- Reconnection driven by `ReconnectPolicy`: the OS holds a pending connect, the policy decides
  when to stop waiting
  - `.none`, `.waitIndefinitely()`, `.giveUp(after:)`, each with an optional re-arm cadence
- Link drop vs user-initiated disconnect are different transitions
  - Link drop → `reconnecting` (if policy allows)
  - `disconnect()` called by the user → `disconnected`, no retry
- Characteristic I/O: async `read`, `write` (with-response and without-response), `notifications(for:) -> AsyncThrowingStream<Data, Error>`
- All I/O on a connection runs in call order through one FIFO queue
- Notification subscriptions are restored automatically across a reconnect; reads and writes fail fast while reconnecting
- Write-without-response includes flow control (wait on `canSendWriteWithoutResponse`)
- Lazy service/characteristic discovery: address characteristics by UUID; the library discovers and caches them per connection
- Escape hatch: `connection.withRaw { peripheral, central in ... }`, scoped to the library's queue
  - Synchronous inspection is safe; mutating connection state is undefined library behavior
  - Callback-based CoreBluetooth calls (RSSI, descriptors, L2CAP) do **not** work through it — their results go to the library's delegate
- Adapter state (powered off / unauthorized / unsupported) surfaced as typed errors
- Unit tests for the state machine and reconnect logic via synthetic events (no hardware), plus an internal protocol seam so the delegate bridge, discovery cache and I/O queue are covered too
- Example app: minimal SwiftUI — scan list, connect, live characteristic value

## Out of scope

Permanently out of scope for this library:

- Peripheral role (advertising / GATT server)
- Classic Bluetooth / MFi
- Objective-C compatibility

Not in 0.1.0 (may be added later):

- Background modes + state restoration
- L2CAP channels
- RSSI read/monitoring — nothing covers it today, so it is first in line
- Descriptor read/write
- Multi-device connection helpers
- Combine adapter layer over the AsyncStreams
- Public protocol abstraction over central for consumer mock-injection
- macOS / watchOS / tvOS / visionOS support
