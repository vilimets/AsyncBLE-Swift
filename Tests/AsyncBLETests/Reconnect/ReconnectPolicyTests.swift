// The policy as a value: .never / .indefinitely / .until(deadline), and the optional re-arm
// cadence. No curve to assert any more — the OS holds the pending connect (PLAN.md §7 Q14).
//
// The engine's behavior is what needs covering: deadline expiry lands in .reconnectGaveUp, the
// deadline keeps running while the adapter is off (§7 Q20), re-arms increment the attempt
// counter, and disconnect() cancels both timers.
