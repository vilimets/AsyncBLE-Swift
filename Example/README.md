# Example app

A small SwiftUI app over AsyncBLE: scan, connect, watch the connection state machine, and
read or subscribe to a characteristic you name.

```bash
open Example/AsyncBLEExample.xcodeproj
```

The project references the package by relative path, so it always builds against the working
copy next to it — no version to bump, and a change to the library shows up on the next build.

## Running it

Simulators have no Bluetooth radio: the app will launch and show "Bluetooth unavailable:
unsupported", which is the adapter banner doing its job and nothing more. **Use a real device.**

Set a development team on the `AsyncBLEExample` target before running on hardware — the project
ships with an empty one so it does not carry anybody's identity in git.

The `NSBluetoothAlwaysUsageDescription` string is set in build settings (`GENERATE_INFOPLIST_FILE`
is on, so there is no `Info.plist` to edit). Without it iOS never shows the permission prompt and
the adapter reports `unauthorized` forever — a mistake worth knowing by sight.

## Reading the log

The device screen's transitions list is timestamped and merges every event — connect, read,
subscribe, and every state change — into one ordered timeline, plus a **Copy Log** button
(top right) that puts the whole thing on the clipboard as plain text: state, transitions, and
notification values, oldest first. Paste that instead of screenshotting a scroll position.

A subscribe is logged in three steps for a reason: `requesting` (the call was made),
`confirmed, awaiting values` (the peripheral accepted the subscription — CoreBluetooth's
`didUpdateNotificationStateFor` came back without error), then either notification values as
they arrive or a final `stream finished, no error, cancelled=…` line. That `cancelled` flag is
the tell for "the app tore this down" (a screen navigation, an `unsubscribe()` tap — task
cancellation ends the stream without an error, same as the library ending it cleanly) versus
"the peripheral or the library ended it" (`cancelled=false`). If you see `confirmed` but the
stream ends moments later with zero values and `cancelled=false`, that is a real gap worth
reporting: the library said the subscription was live and then closed it with nothing to show
for it.

`operationNotSupported` on a read or subscribe usually is not a bug — it means the
characteristic's GATT properties do not include that operation. Heart Rate Measurement (`2A37`)
is a good example: notify-only, no `Read` property, so reading it should throw exactly this.
Check the characteristic's properties (LightBlue shows them) before treating this as a failure.

## What it is for

It is the manual smoke test in the plan's Phase 2 definition of done, which is why it is generic
rather than wired to one peripheral. Point it at whatever hardware is on the desk.

Worth doing at least once, in this order:

1. **Scan.** Names, identifiers and RSSI should appear, and the list should stop updating the
   moment you leave the screen — a scan that outlives its consumer is a battery bug the library
   is supposed to prevent.
2. **Connect**, then read a characteristic by UUID. `2A19` (battery level) is a good first try;
   most peripherals have it. Lazy discovery runs on the first read, so the first one is slower
   than the second — the state transition list shows nothing in between, which is the point.
3. **Subscribe** to something that notifies. `2A37` on a heart-rate strap.
4. **Walk out of range with the screen open.** This is the test the whole library exists for:
   the state list should show `connected → reconnecting(attempt: 1)`, and the notification
   stream should keep going — not throw, not finish — when you walk back and it returns to
   `connected`. Nothing in the app re-subscribes; the library does it underneath.
5. **Turn Bluetooth off in Control Center while reconnecting.** With the default indefinite
   policy the connection should stay `reconnecting` and pick up again when you turn it back on.
6. **Disconnect.** The state stream finishes, the notification stream finishes without throwing,
   and the connection drops off `Central.activeConnections`.

## What it is not

Not a BLE explorer, and not a showcase of every API. It exists to prove the library reads well
at a real call site and behaves on real hardware, so it stays small on purpose — two files, no
dependencies, no architecture.
