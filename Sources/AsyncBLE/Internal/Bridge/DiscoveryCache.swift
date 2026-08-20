// Lazy service/characteristic discovery, cached per connection.
//
// Hardest part of Phase 2 (PLAN.md §5): concurrent callers asking for the same characteristic
// must coalesce onto one in-flight discovery, not start N of them.
//
// And the cache is not stable for the life of the connection — CoreBluetooth invalidates every
// CBService/CBCharacteristic on disconnect, so a reconnect flushes it, re-walks discovery, and
// restores whatever notification subscriptions were live (PLAN.md §7 Q2).
