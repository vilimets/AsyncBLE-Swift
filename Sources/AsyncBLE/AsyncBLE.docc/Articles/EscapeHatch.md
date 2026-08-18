# Using the escape hatch

Reach the underlying CoreBluetooth objects, and understand what you give up when you do.

## Overview

AsyncBLE covers the common central-role work, not all of CoreBluetooth. Descriptors, L2CAP
channels, and RSSI monitoring are outside the 0.1.0 scope, and a wrapper that hides the objects
underneath would leave you stuck the moment you need one of them.

So the objects are available. A connection exposes its `CBPeripheral` and the `CBCentralManager`
behind it through `raw`.

### The contract

> Important: Reading through `raw` is safe. Mutating connection state through it is not.

Reading is fine: inspect the peripheral's services, check identifiers, read properties, log
diagnostics. AsyncBLE does not care that you looked.

Mutating connection state is not. Calling `cancelPeripheralConnection`, initiating your own
connect, or reassigning the peripheral's delegate puts the library into undefined behavior.
The state machine believes it holds the only handle on the link; change the link behind its back
and the state it reports becomes fiction. Reconnection may fire when it should not, or not fire
when it should.

Reassigning the delegate is the sharpest edge of the three. AsyncBLE's bridge is that delegate,
and the events it translates are the only input the state machine has. Take it away and the
connection stops observing itself.

### When you need more than reading

If you find yourself wanting to mutate through `raw`, that is a signal worth acting on rather
than working around. Open an issue describing the use case. Several capabilities are already
planned — descriptor access, RSSI monitoring, L2CAP channels, background state restoration — and
a concrete use case is what moves one up the list.

Until then, an escape hatch you use read-only is a safety valve. One you use to steer is a bug
waiting for a bad day.
