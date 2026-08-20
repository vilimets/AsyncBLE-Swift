// Internal protocols over CBCentralManager / CBPeripheral, so the bridge, discovery cache,
// write queue and reconnect path can be driven by fakes (PLAN.md §7 Q7).
//
// Deliberately `internal`: this is not the public mock-injection abstraction, which stays on
// the Planned list. It exists so the risky 70% of the library has automated coverage without
// taking a dependency that would put CBM* typealiases through the production source.
