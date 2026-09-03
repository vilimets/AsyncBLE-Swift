# Connection lifecycle

The states a connection moves through, what drives each transition, and how to observe them.

## Overview

Every connection in AsyncBLE is in exactly one of four states, and every change of state comes
from a single pure state machine. There is no second source of truth to fall out of sync with.

![Connection state machine with four states. Disconnected is the initial and terminal state. Calling connect moves to Connecting, which is guarded by a timeout. When discovery finishes, Connecting moves to Connected, where input and output are available. A link drop moves Connected to Reconnecting, where a pending connect stays armed. The peripheral returning moves it back to Connected; the policy's deadline expiring returns it to Disconnected.](connection-state-machine)

### The states

- **Disconnected.** The initial and terminal state. It carries the reason it was entered, which
  is `nil` when you disconnected on purpose.
- **Connecting.** A connection attempt is in flight, guarded by the connect timeout from your
  configuration. CoreBluetooth has no native timeout, so this guard is AsyncBLE's own.
- **Connected.** The link is up and characteristic I/O is available.
- **Reconnecting.** The link dropped and the policy is still waiting for it to come back. A
  pending connect stays armed the whole time and the OS fulfils it when the peripheral returns.
  The attempt number counts arms of that request, not retries — so with the default policy it
  reads `1` for the whole outage, because there is one request in flight throughout.

### Observing state

State escapes a connection through an `AsyncStream`, never through a delegate or a completion
handler. `Connection` is an actor, and the stream is the only channel out. Iterate it with
`for await` and drive your UI directly from it.

Because state is a stream rather than a property you poll, there is no window where your UI and
the connection disagree.

### Deliberate disconnect versus link drop

This is the distinction most wrappers get wrong, and it is worth understanding.

CoreBluetooth fires the same delegate callback whether the user walked out of range or your own
code called `cancelPeripheralConnection`. A wrapper that treats both identically will either
reconnect when the user asked it to stop, or fail to reconnect when the link genuinely dropped.

AsyncBLE tracks which one happened and routes the transition accordingly:

| What happened | Where it goes |
| --- | --- |
| Link dropped on its own | Reconnecting, if the policy waits at all |
| You called `disconnect()` | Disconnected, with no waiting |

A `disconnect()` while reconnecting cancels the pending connect and the give-up deadline. There
are no zombie timers waking up later to reconnect a device you deliberately let go.

> Important: A link is a device-wide resource, not a per-caller session. Two parts of your app
> connecting to the same peripheral share one connection, so `disconnect()` ends it for both.

### Why a pure state machine

The transition table is a value-in, value-out function: it takes the current state and an event,
and returns the next state plus a list of effects for the caller to perform. It does not import
CoreBluetooth, does not start timers, and does not know what a peripheral is.

That constraint pays off in tests. Every transition, including the awkward ones like a timeout
firing while a disconnect is already in flight, is covered by feeding synthetic events to a plain
Swift type. No hardware, no simulator, no mocking of Apple's classes.

The layer underneath — the delegate bridge, the discovery cache, the I/O queue — is tested the
same way, against an internal protocol seam with hand-written fakes standing in for the
CoreBluetooth managers.
