// CBCentralManagerDelegate → state machine events / async continuations.
//
// Translates only; never sets state directly (PLAN.md §3, invariant 3). Talks to the manager
// through the seam, not to CBCentralManager directly.
//
// Also owns the adapter-state broadcast behind `Central.adapterStates` (PLAN.md §7 Q5).
