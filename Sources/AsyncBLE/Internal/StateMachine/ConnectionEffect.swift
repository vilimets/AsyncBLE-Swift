// Outputs of the state machine: side effects for the caller to perform — arm/cancel a CB
// connect, arm/cancel the timeout, start/stop the give-up deadline, arm/cancel the re-arm
// timer, invalidate the discovery cache, restore subscriptions, fail queued I/O.
//
// Effects are values, not closures — that keeps them assertable in tests.
