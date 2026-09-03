# ``AsyncBLE``

Talk to Bluetooth Low Energy peripherals with async/await, an observable connection state
machine, and reconnection you configure instead of write.

## Overview

AsyncBLE wraps CoreBluetooth for the central role. It exists because three things are painful
in every CoreBluetooth codebase, and every codebase solves them again from scratch:

- **Connection timeouts.** `connect(_:options:)` has no timeout. It waits forever, and you find
  out only when a user complains.
- **Connection state.** The truth is spread across a `CBPeripheral.state` enum, a handful of
  delegate callbacks, and whatever booleans you added under deadline.
- **Reconnection.** CoreBluetooth already retries a pending connect indefinitely, and most
  codebases reimplement that badly with a timer anyway. What it never does is tell you what is
  happening, or give up.

AsyncBLE answers each one directly: a configurable connect timeout, a single observable state
machine, and reconnection as a value you pass in — one that decides when to *stop* waiting,
while the OS does the waiting.

CoreBluetooth types stay out of the public API. The one deliberate exception is `CBUUID`, used
as the characteristic identifier, plus the objects handed to the `withRaw` escape hatch when you
need them. See <doc:EscapeHatch>.

### Layering

Dependencies point downward only. The public layer creates connections; the engine layer holds
the pure state machine, the reconnect driver, and the CoreBluetooth bridge; CoreBluetooth sits
at the bottom and never leaks upward.

![The three layers of AsyncBLE: a public API layer containing Central and Connection, an internal engine layer containing the state machine, reconnect engine, I/O queue, and delegate bridge, and CoreBluetooth underneath.](architecture)

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

### Seeing what happened

- <doc:Diagnostics>

### Scanning

- ``Central``
- ``ScanOptions``
- ``Discovery``
- ``AdvertisementData``

### Connections

- ``Connection``
- ``ConnectionState``
- ``DisconnectReason``
- ``AdapterState``
- ``Connection/WriteMode``

### Configuration

- ``Central/Configuration``
- ``ReconnectPolicy``

### Logging

- ``Logging``
- ``LogLevel``
- ``LogCategory``
- ``LogRecord``
- ``LogHandler``
- ``OSLogHandler``

### Errors

- ``BluetoothError``
- ``UnavailableReason``
