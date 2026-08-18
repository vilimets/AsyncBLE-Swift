// Outputs of the state machine: side effects for the caller to perform (start CB connect,
// arm/cancel the timeout timer, schedule a retry, cancel CB connect).
//
// Effects are values, not closures — that keeps them assertable in tests.
