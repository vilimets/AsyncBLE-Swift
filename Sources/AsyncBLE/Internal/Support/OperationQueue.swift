// The per-connection FIFO that all reads and writes pass through (PLAN.md §7 Q4, Q11).
//
// Actor isolation alone does not order anything: `write` suspends for discovery and for
// `canSendWriteWithoutResponse`, and reentrancy at those points lets concurrent callers
// interleave. This restores call order — which costs almost nothing, since ATT permits one
// outstanding request per connection anyway.
//
// On a drop, queued operations fail in order with `.disconnected` before any new I/O is taken.
