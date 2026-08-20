// AsyncBLE — a Swift concurrency wrapper over CoreBluetooth (central role).
//
// Layering (see PLAN.md §3), dependencies point downward only:
//   Public/    — the API surface. No CoreBluetooth types except inside `Connection.raw`.
//   Internal/  — engine: pure state machine, reconnect policy driver, CoreBluetooth bridge.
//
// Phase 1 populates Public/. Phase 2 populates Internal/.
//
// `@preconcurrency import CoreBluetooth`: CoreBluetooth is not Sendable-audited, so `CBUUID` —
// the one CoreBluetooth type allowed in public signatures (PLAN.md §3) — trips strict-concurrency
// diagnostics despite being an immutable value type. The attribute states that assumption at the
// import instead of adding a retroactive `Sendable` conformance, which a library has no business
// declaring on another module's type.
