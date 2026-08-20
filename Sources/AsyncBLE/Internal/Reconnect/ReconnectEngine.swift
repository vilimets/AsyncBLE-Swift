// Keeps a dropped link's connect request armed, and decides when to stop waiting.
//
// Not a retry loop: CoreBluetooth's pending connect already reconnects indefinitely, scheduled
// by the radio (PLAN.md §7 Q14). This owns the give-up deadline, the optional re-arm cadence,
// and the arm counter behind `reconnecting(attempt:)`.
//
// The deadline is wall-clock and keeps running while the adapter is off (§7 Q20). Owns its
// timers so `disconnect()` can cancel them — no zombie waits.
