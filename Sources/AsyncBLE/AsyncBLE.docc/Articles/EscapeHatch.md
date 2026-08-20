# Using the escape hatch

Reach the underlying CoreBluetooth objects, and understand exactly what you can do with them.

## Overview

AsyncBLE covers the common central-role work, not all of CoreBluetooth. A wrapper that hides the
objects underneath would leave you stuck the moment you need something it does not cover, so the
objects are available — through a scoped call rather than a property:

```swift
let mtu = await connection.withRaw { peripheral, _ in
    peripheral.maximumWriteValueLength(for: .withoutResponse)
}
```

The closure runs on the library's own queue. That is not ceremony: `CBPeripheral` is not
thread-safe, and a property handing it out for you to read on the main actor would be offering a
data race with a reassuring doc comment attached. The return value must be `Sendable`, which is
what stops a `CBPeripheral` or `CBService` escaping the closure into a context where touching it
would race.

### The contract

> Important: Synchronous inspection is safe. Mutating connection state is not. Callback-based
> operations do not work at all.

**Reading is fine.** Inspect the peripheral's services, check identifiers, read properties,
pull out values, log diagnostics. AsyncBLE does not care that you looked.

**Mutating connection state is undefined behavior.** Calling `cancelPeripheralConnection`,
initiating your own connect, or reassigning the peripheral's delegate puts the library into
undefined behavior. The state machine believes it holds the only handle on the link; change the
link behind its back and the state it reports becomes fiction.

Reassigning the delegate is the sharpest edge of the three. AsyncBLE's bridge is that delegate,
and the events it translates are the only input the state machine has. Take it away and the
connection stops observing itself.

### What the escape hatch cannot do

This is worth stating plainly, because it is easy to assume otherwise.

`readRSSI()`, `readValue(for: descriptor)`, `writeValue(_:for: descriptor)` and L2CAP channel
opening are all **callback-based**: you issue the request, and the result arrives at the
peripheral's delegate. That delegate is AsyncBLE's bridge, not you. The call will appear to
succeed and the result will be dropped on the floor.

So the escape hatch is a window, not a door. It covers synchronous inspection completely and
asynchronous operations not at all. RSSI reads, descriptor access and L2CAP need real API
support in this library — they are tracked as planned work, and RSSI is prioritized precisely
because nothing else covers it.

### When you need more than reading

If you find yourself wanting to mutate through `withRaw`, that is a signal worth acting on
rather than working around. Open an issue describing the use case. Several capabilities are
already planned — descriptor access, RSSI monitoring, L2CAP channels, background state
restoration — and a concrete use case is what moves one up the list.

Until then, an escape hatch you use read-only is a safety valve. One you use to steer is a bug
waiting for a bad day.
