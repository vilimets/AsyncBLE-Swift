// AsyncBLE — a Swift concurrency wrapper over CoreBluetooth (central role).
//
// Layering (see PLAN.md §3), dependencies point downward only:
//   Public/    — the API surface. No CoreBluetooth types except inside `Connection.raw`.
//   Internal/  — engine: pure state machine, reconnect policy driver, CoreBluetooth bridge.
//
// Phase 1 populates Public/. Phase 2 populates Internal/.
