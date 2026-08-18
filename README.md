# AsyncBLE

A modern Swift wrapper over CoreBluetooth (central role) with three first-class features that existing wrappers treat as afterthoughts:

1. **Explicit connection state machine** — observable, testable, single source of truth
2. **Auto-reconnect with configurable backoff** — the code everyone writes by hand, badly
3. **async/await API** — no delegates, no CoreBluetooth types in public signatures

Target audience: iOS developers integrating BLE devices.

**Platforms:** iOS 16+, Swift 5.9+, Swift Package Manager only.

## In scope (0.1.0)

- Central role only
- Scanning: `AsyncStream<Discovery>`, service UUID filter, allow-duplicates option
- `connect(_:) async throws -> Connection` with configurable timeout (CoreBluetooth has no native connect timeout)
- Connection state machine, observable via `AsyncStream<ConnectionState>`
  - States: `disconnected`, `connecting`, `connected`, `reconnecting(attempt:)`
- Auto-reconnect driven by `ReconnectPolicy`
  - Presets: `.none`, `.exponentialBackoff(maxAttempts:)`, plus a closure-based custom curve
- Link drop vs user-initiated disconnect are different transitions
  - Link drop → `reconnecting` (if policy allows)
  - `disconnect()` called by the user → `disconnected`, no retry
- Characteristic I/O: async `read`, `write` (with-response and without-response), `notifications(for:) -> AsyncStream<Data>`
- Write-without-response includes flow control (wait on `canSendWriteWithoutResponse`)
- Lazy service/characteristic discovery: address characteristics by UUID; the library discovers and caches them per connection
- `.raw` escape hatch: `connection.raw.peripheral`, `connection.raw.central`
  - Reading is safe; mutating connection state through raw objects is undefined library behavior
- Adapter state (powered off / unauthorized / unsupported) surfaced as typed errors
- Unit tests for the state machine and reconnect logic via synthetic events (no hardware)
- Example app: minimal SwiftUI — scan list, connect, live characteristic value

## Out of scope

Permanently out of scope for this library:

- Peripheral role (advertising / GATT server)
- Classic Bluetooth / MFi
- Objective-C compatibility

Not in 0.1.0 (may be added later):

- Background modes + state restoration
- L2CAP channels
- Descriptor read/write (`.raw` covers it for now)
- RSSI read/monitoring
- Multi-device connection helpers
- Combine adapter layer over the AsyncStreams
- Protocol abstraction over central for mock-injection
- macOS / watchOS / tvOS / visionOS support
