# Reconnection

Configure retry behavior with a policy instead of hand-rolling timers.

## Overview

When a BLE link drops, something has to decide whether to try again, how long to wait, and when
to give up. In most codebases that decision is scattered across a timer, a counter, and a
comment apologizing for both.

In AsyncBLE it is a value you pass in when you create a central. A policy answers exactly one
question: given attempt number N, how long should we wait before trying again — or should we
stop entirely?

### Choosing a policy

- **No reconnection.** A drop ends the connection. Appropriate when the user should decide
  whether to reconnect, or when a dropped link means the workflow is over.
- **Exponential backoff.** The default. Waits grow with each attempt up to a ceiling, and the
  policy gives up after a maximum number of attempts. This is what you want for a device the
  user expects to stay paired with.
- **A custom curve.** Supply a closure from attempt number to a delay, returning `nil` to stop.
  Use it for a fixed interval, a curve tuned to your hardware's advertising interval, or a
  schedule that gives up quickly on battery-powered peripherals.

### Why backoff, not a fixed retry

Retrying immediately and forever is the failure mode worth designing against. A peripheral that
is out of range, powered off, or busy will not answer, and hammering it drains both batteries
while filling your logs. Backoff spends radio time in proportion to how likely the next attempt
is to succeed.

The ceiling matters as much as the growth. Without one, a long outage pushes the delay so far out
that the device stays disconnected long after it came back into range.

### What you observe

Reconnection is visible, not hidden. Each attempt moves the connection into the reconnecting
state carrying its attempt number, so a UI can show real progress rather than an indefinite
spinner. When the policy gives up, the connection lands in disconnected with a reason saying so.

See <doc:ConnectionLifecycle> for how these transitions fit together.

### Testing your policy

Policies are pure and synchronous: attempt number in, delay out. You can assert your curve's
behavior — its growth, its ceiling, and where it gives up — in a unit test with no clock and no
waiting.
