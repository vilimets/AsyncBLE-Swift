// One test per row of the transition table in PLAN.md §4, plus the explicit edge cases:
//   - disconnect() while reconnecting cancels the timer (no zombie retry)
//   - connect() while already connecting
//   - Bluetooth powered off mid-connection
//
// Working agreement: a state machine change lands with its test in the same commit.
