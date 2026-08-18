# Getting started

Add the package, scan for a peripheral, connect to it, and read a characteristic.

## Overview

> Note: The API ships in 0.1.0 and this article is written against it as it lands. Code samples
> arrive with the Phase 1 API surface; the shape below is the contract the design is held to.

## Installation

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

## Permissions

iOS requires a usage description before it will let your app touch Bluetooth. Add
`NSBluetoothAlwaysUsageDescription` to your `Info.plist` and write a sentence a user would
actually understand — the string is shown in the system prompt.

Bluetooth does not work in the simulator. Test on a device.

## The shape of a session

A typical session has four steps, and AsyncBLE keeps each one to a single expression:

1. Create a central, optionally with a configuration that sets the connect timeout and the
   reconnect policy.
2. Scan, filtering by service UUID, and consume discoveries from an `AsyncStream`.
3. Connect, awaiting a `Connection` or catching a typed error.
4. Read, write, or subscribe to characteristics by UUID. Service and characteristic discovery
   happens lazily underneath and is cached for the life of the connection.

You never write a delegate, and you never see a `CBPeripheral` unless you ask for it through
<doc:EscapeHatch>.

## Next steps

- <doc:ConnectionLifecycle> explains the states a connection moves through and when.
- <doc:Reconnection> covers what happens after the link drops.
