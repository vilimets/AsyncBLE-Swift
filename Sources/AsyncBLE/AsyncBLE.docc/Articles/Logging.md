# Logging

See what the library is doing — and why — without patching it.

## Overview

Everything AsyncBLE does that you can observe through its API tells you *that* something
happened: a state stream yields `reconnecting`, a `read` throws. None of it tells you *why* the
reconnect gave up, or which discovery walk failed. Logging fills that gap.

The library logs to Apple's unified logging system (OSLog) by default. You configure it once,
when you create the ``Central`` — there is no runtime setter, because OSLog is normally retuned
from outside the process and a mutable knob would buy little.

```swift
// Default: OSLog, on, at .notice.
let central = Central()

// More detail.
let central = Central(logging: .init(minimumLevel: .debug))

// Off.
let central = Central(logging: .init(isEnabled: false))
```

### Levels

Four levels, mapping one-to-one onto `OSLogType`, so what you set is what Console and the `log`
tool filter on:

| ``LogLevel`` | `OSLogType` | What lands here |
|---|---|---|
| ``LogLevel/debug`` | `.debug` | Per-callback tracing, cache hits, effect dispatch |
| ``LogLevel/info`` | `.info` | Each read, write, subscribe, and the discovery walk |
| ``LogLevel/notice`` | `.default` | Connect, disconnect, reconnect arming, adapter changes, scans |
| ``LogLevel/error`` | `.error` | Errors thrown to you, operations the peripheral refused, failed restores |

The default is ``LogLevel/notice`` — enough to follow a link's life, quiet enough to leave on.

### Categories

Every record carries a ``LogCategory``, which becomes an OSLog category so you can narrow the
stream:

- `central` — the adapter, scanning, connect requests, the connection registry
- `connection` — the state machine: transitions and the effects they trigger
- `io` — characteristic reads, writes, and notification subscriptions
- `discovery` — the service and characteristic walk, and the per-link cache
- `reconnect` — pending-connect arming, the give-up deadline, the re-arm cadence, subscription restore
- `bridge` — the raw CoreBluetooth delegate callbacks, before the library interprets them (`debug` only)

### Viewing OSLog output

In Console.app, filter on `subsystem: com.asyncble`. From the terminal:

```
log stream --predicate 'subsystem == "com.asyncble"' --level debug
log stream --predicate 'subsystem == "com.asyncble" && category == "reconnect"'
```

### Sending it somewhere else

Implement ``LogHandler`` and pass it in. This is also how you assert on logging in tests — a
handler that keeps every ``LogRecord``.

```swift
struct MyLogHandler: LogHandler {
    func log(_ record: LogRecord) {
        myLogger.log(level: record.level, "\(record.category): \(record.message)")
    }
}

let central = Central(logging: .init(minimumLevel: .debug, handler: MyLogHandler()))
```

A handler is called on the library's serial queue. If it does real work, hop off first.

### What is and is not logged

> Important: The bytes of a characteristic value are never logged — only a length. A read that
> returns 20 bytes logs `20B`, not the payload.

Identifiers *are* logged in full: peripheral UUIDs and characteristic UUIDs appear in messages
and in ``LogRecord/metadata``. A peripheral's identifier is a random value CoreBluetooth assigns
per app; it is not stable across apps or devices and is not a tracking vector. It is also the
only useful key for correlating a run's events, so redacting it would cost the logs most of
their value.
