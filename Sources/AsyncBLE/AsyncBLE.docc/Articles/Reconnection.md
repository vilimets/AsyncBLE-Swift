# Reconnection

Let the OS do the retrying. Decide for yourself when to stop.

## Overview

When a BLE link drops, something has to decide whether to keep trying and when to give up. In
most codebases that decision is scattered across a timer, a counter, and a comment apologizing
for both.

The surprise is that the timer was never needed. CoreBluetooth's `connect(_:options:)` has no
timeout by design: the request stays armed and the system fulfils it whenever the peripheral
comes back into range — hours later, if that is how long it takes, scheduled by the radio rather
than by your app waking up to poll. A hand-rolled backoff loop spends more power to do the same
job worse.

So AsyncBLE does not reimplement retrying. It re-arms the pending connect and adds the two
things CoreBluetooth will not give you: **a view of what is happening**, and **a decision about
when to stop**.

### Choosing a policy

- **No reconnection.** A drop ends the connection. Appropriate when the user should decide
  whether to reconnect, or when a dropped link means the workflow is over.
- **Wait indefinitely.** The default. The link comes back whenever the device does. This is the
  right answer for a device the user expects to stay paired with — a wearable out of range for
  twenty minutes is not a failed connection, it is a wearable out of range. It costs nothing
  while waiting, because the OS is doing the waiting.
- **Give up after a deadline.** For workflows with a natural end: a setup screen that should not
  wait forever, a scale reading that is stale after two minutes.

Each of these optionally takes a re-arm interval, which cancels and re-issues the pending
connect on a cadence. Leave it alone unless you are working around a CoreBluetooth connection
that gets wedged and never fulfils — re-issuing sometimes shakes one loose. It is a workaround,
and it is documented as one.

### The deadline is wall-clock

A give-up deadline counts real time from the moment the link dropped, and it keeps counting
while Bluetooth is switched off. A deadline shorter than a user's trip through Control Center
will end the connection. This is a deliberate trade: a deadline that pauses is harder to reason
about and harder to test than one that means what it says. If it matters, wait indefinitely and
end the connection yourself.

### What you observe

Waiting is visible, not hidden. A dropped link moves the connection into the reconnecting state,
and the connection stays there until the peripheral returns or the policy gives up. When it does
give up, the connection lands in disconnected with a reason saying so.

The attempt number in that state counts *arms* of the pending connect, not retries. With no
re-arm interval set there is exactly one arm, so it will read `1` for the whole outage — because
there genuinely is one connect request in flight the entire time. That is the honest number; a
UI that wants to show progress should show elapsed time instead.

### Your subscriptions come back

A reconnect that only restores the link would leave you rewiring everything on top of it.
CoreBluetooth invalidates every service and characteristic object when a link drops, so AsyncBLE
flushes its discovery cache, re-walks discovery on the new link, and re-subscribes the
notification streams you were already holding. The same stream keeps yielding.

Values sent while the link was down are gone — nothing can recover those. Watch the state stream
if you need to know a gap happened. And if the subscription genuinely cannot be restored, the
stream throws rather than quietly stopping, so you can tell a dead subscription from a quiet
sensor.

Reads and writes are the opposite: they fail immediately while reconnecting rather than queueing
up. A command composed against the device's pre-drop state should not land on a device that may
have rebooted into a different one.

See <doc:ConnectionLifecycle> for how these transitions fit together.

### Testing your policy

A policy is a value — a persistence mode and an optional interval — with no closures and no
clock. You can assert what it says in a unit test with no waiting. The engine that acts on it is
tested the same way, against a fake clock and a fake central.
