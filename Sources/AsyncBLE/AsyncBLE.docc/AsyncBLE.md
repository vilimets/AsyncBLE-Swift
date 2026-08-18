# ``AsyncBLE``

Talk to Bluetooth Low Energy peripherals with async/await, an observable connection state
machine, and reconnect logic you configure instead of write.

## Overview

AsyncBLE wraps CoreBluetooth for the central role. It exists because three things are painful
in every CoreBluetooth codebase, and every codebase solves them again from scratch:

- **Connection timeouts.** `connect(_:options:)` has no timeout. It waits forever, and you find
  out only when a user complains.
- **Connection state.** The truth is spread across a `CBPeripheral.state` enum, a handful of
  delegate callbacks, and whatever booleans you added under deadline.
- **Reconnection.** Everyone writes it, most write it wrong, and the bugs surface as retry
  storms or links that never come back.

AsyncBLE answers each one directly: a configurable connect timeout, a single observable state
machine, and reconnection as a value you pass in.

CoreBluetooth types stay out of the public API. The one deliberate exception is `CBUUID`, used
as the characteristic identifier, and the `raw` escape hatch when you need the underlying
objects. See <doc:EscapeHatch>.

### Layering

Dependencies point downward only. The public layer creates connections; the engine layer holds
the pure state machine, the reconnect driver, and the CoreBluetooth bridge; CoreBluetooth sits
at the bottom and never leaks upward.

![The three layers of AsyncBLE: a public API layer containing BLECentral and Connection, an internal engine layer containing the state machine, reconnect engine, and delegate bridge, and CoreBluetooth underneath.](architecture)

The state machine at the center is a pure function of events to states and effects. It imports
Foundation and nothing else, which is what makes the whole transition table testable without
hardware and without mocking Apple's classes.

### Requirements

- iOS 16 or later
- Swift 5.9 or later
- Swift Package Manager

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:ConnectionLifecycle>

### Staying connected

- <doc:Reconnection>

### Going lower level

- <doc:EscapeHatch>

<!-- Symbol curation lands with the Phase 1 API. Uncomment as the types appear, so the
     documentation build stays warning-free in the meantime.

### Scanning

- ``BLECentral``
- ``Discovery``
- ``AdvertisementData``

### Connections

- ``Connection``
- ``ConnectionState``
- ``DisconnectReason``

### Configuration

- ``BLECentralConfiguration``
- ``ReconnectPolicy``

### Errors

- ``BLEError``
-->
