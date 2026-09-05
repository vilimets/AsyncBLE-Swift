# Running in the background

Keep a link alive while your app is not, and pick it back up when iOS relaunches you.

## Overview

An app connected to a BLE accessory does not stay running. iOS suspends it when the user leaves,
and terminates it under memory pressure some time later. Without preparation the link dies with
the process, and the next launch starts from nothing: scan, find, connect, rediscover,
re-subscribe — while the user waits.

CoreBluetooth's answer is **state restoration**. iOS keeps the connections and the pending
connect requests your app was holding, and relaunches the app in the background when something
happens to one of them. AsyncBLE hands those back as ordinary ``Connection`` objects through
``Central/restoredConnections``.

This is not the same as running in the background. Your app is not running: it is asleep, and
iOS wakes it for a few seconds at a time when the radio has something to say.

### Turning it on

Two things, and neither works without the other.

**1. Declare the background mode.** In your target's Info settings, add `bluetooth-central` to
`UIBackgroundModes`. Without it iOS never relaunches the app, and there is nothing to restore
into.

**2. Give the central a restore identifier.**

```swift
let central = Central(
    configuration: Central.Configuration(restoreIdentifier: "com.example.app.central")
)
```

The identifier must be **stable across launches** — it is the key iOS files the state under, so
a fresh `UUID()` each launch restores nothing, every time, silently. Use a constant. If your app
creates more than one central, give each its own.

### Picking the links back up

Create the central as early in launch as you can — restoration is delivered to it, and a central
created three screens later has missed nothing but has kept the app awake for no reason in the
meantime. Then read ``Central/restoredConnections``:

```swift
for await connection in central.restoredConnections {
    Task {
        for try await beat in try await connection.notifications(for: measurement) {
            await store.record(beat)
        }
    }
}
```

The stream replays: it yields everything restored so far to each new subscriber, so there is no
race to lose. This matters more than it looks. Restoration is delivered before your app has run
a line of its own code, so *every* subscriber is a late one — a plain property would be a coin
toss on how fast your launch path is.

Restored connections are also in ``Central/activeConnections``, alongside anything this launch
connected itself.

### What comes back, and what does not

A restored connection is not a snapshot of the old one. It is a new object around a link that
happens to have survived.

| Survives | Does not |
| --- | --- |
| The link itself, and its state | The `Connection` object from the old process |
| The peripheral's notify flags | The notification `AsyncStream`s you were iterating |
| A pending connect the OS was holding | The discovery cache |
| The peripheral's identifier | Anything your app kept in memory |

The practical shape of that: **re-subscribe to everything you care about.** The peripheral is
very likely still notifying — iOS keeps the flag — so the first `notifications(for:)` after a
restoration attaches to the live subscription and costs no round trip to the peripheral. It is
cheap, and it is the only way to get the values, because the stream that was carrying them died
with the process.

The corollary: a characteristic left notifying that nothing re-subscribes to keeps delivering
into nothing until the connection closes. AsyncBLE does not turn those off on your behalf — iOS
preserved that flag deliberately and guessing which ones you no longer want would throw away
the thing that makes restoration fast. Call ``Connection/disconnect()`` on a restored link you
have no further use for.

### What the OS will and will not do while you sleep

- **Connecting works.** A pending connect — from ``Central/connectWhenInRange(_:)``, or from
  AsyncBLE re-arming after a drop — is serviced by the system while your app is terminated, and
  fulfilling it is what relaunches you. This is the mechanism the whole reconnect design rests
  on; see <doc:Reconnection>.
- **Filtered scanning works, slowly.** A scan with a service filter continues in the background
  at a much reduced duty cycle.
- **Unfiltered scanning does not work at all.** An empty ``ScanOptions/services`` scans for
  everything, which iOS refuses to do in the background. Always filter if a scan needs to
  survive backgrounding.
- **A scan restored from the previous process is stopped.** The stream that was consuming it
  died with the process, and a scan nobody is reading is a battery bug. Start a new one if you
  want one.

### Testing it

None of this can be checked in the Simulator, and no unit test proves it: the library's own
tests cover what it does when told a restoration happened, not the restoration itself. The real
test takes a device, a peripheral, and a walk.

1. Run the app on a device. Connect, and subscribe to a notifying characteristic.
2. Background the app.
3. Terminate it **from Xcode** — press Stop. Do *not* swipe up in the app switcher: that is the
   user saying "stop doing things", and iOS honours it by never relaunching the app.
4. Walk the peripheral out of range and back, so that the reconnect fires.
5. Attach the debugger — Xcode ▸ Debug ▸ Attach to Process by PID or Name — and confirm the
   library logs the restoration, ``Central/restoredConnections`` yields the link, and
   re-subscribing resumes values without a reconnect.

Set ``LogConfiguration`` to ``LogLevel/debug`` while doing this. Restoration is logged in the
`central` category; see <doc:Diagnostics>.

## Topics

### Configuration

- ``Central/Configuration/restoreIdentifier``
- ``Central/restoredConnections``
