# Getting started

Add the package, scan for a peripheral, connect to it, and read a characteristic.

## Overview

### Installation

Add AsyncBLE to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/vilimets/AsyncBLE-Swift.git", from: "0.1.0")
]
```

Then add it to your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "AsyncBLE", package: "AsyncBLE-Swift")
    ]
)
```

In Xcode, use File > Add Package Dependencies and paste the same URL.

### Permissions

iOS requires a usage description before it will let your app touch Bluetooth. Add
`NSBluetoothAlwaysUsageDescription` to your `Info.plist` and write a sentence a user would
actually understand — the string is shown in the system prompt.

Bluetooth does not work in the simulator. Test on a device.

### The shape of a session

Scan, connect, read, disconnect — each one expression, no delegates:

```swift
import AsyncBLE

let heartRate = ServiceID(string: "180D")
let measurement = CharacteristicID(string: "2A37")

let central = Central()

for await device in try await central.scan(services: [heartRate]) {
    let connection = try await central.connect(device)

    // One-shot read.
    let bytes = try await connection.read(measurement)
    print("\(bytes.count) bytes")

    // Or subscribe, and let the peripheral push.
    for try await notification in try await connection.notifications(for: measurement) {
        print(notification)
        break
    }

    await connection.disconnect()
    break
}
```

Service and characteristic discovery happens lazily underneath, is cached for as long as the
link lives, and is rebuilt for you if the link drops and returns. Note there is no
`import CoreBluetooth`: ``ServiceID`` and ``CharacteristicID`` are the library's names for the
one Apple type that reaches the public API, so you never see a `CBPeripheral` unless you ask for
one through <doc:EscapeHatch>.

### Giving a characteristic a type

Addressing by UUID gets you `Data`. If you would rather deal in your own types, declare the
characteristic once with the type it carries and the decoding follows every call site:

```swift
enum Battery {
    static let level = Characteristic<UInt8>("2A19")
}

let percent = try await connection.read(Battery.level)   // UInt8, not Data
```

`UInt8` through `Int64`, `String` and `Data` are supported out of the box; conform your own
types to ``CharacteristicDecodable`` (and ``CharacteristicEncodable`` to write them). The typed
calls are the untyped ones with a codec wrapped around them — same queueing, same discovery,
same reconnect behaviour.

Bluetooth being switched off is not an exception to handle once — it is a state to observe.
`adapterStates` on the central tells you when it changes, which is what a "Bluetooth is off"
banner should be driven by.

### Next steps

- <doc:ConnectionLifecycle> explains the states a connection moves through and when.
- <doc:Reconnection> covers what happens after the link drops.
- <doc:Diagnostics> covers what the library logs and how to redirect it.
- <doc:EscapeHatch> is there for the parts of CoreBluetooth this library does not wrap.
