// Test helpers: event sequence builders, a fake clock, and the fakes behind the CoreBluetooth
// seam (PLAN.md §7 Q7) that emit synthetic delegate callbacks.
//
// No mocks of Apple classes — the state machine never sees CoreBluetooth (PLAN.md §2), and the
// bridge sees only our own protocols.
