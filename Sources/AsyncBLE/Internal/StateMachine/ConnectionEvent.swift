// Inputs to the state machine (PLAN.md §4): connectRequested, didConnect, didFailToConnect,
// didDisconnect(error:userInitiated:), connectTimedOut, disconnectRequested, reArmTimerFired,
// giveUpDeadlineReached, adapterChanged(AdapterState).
//
// `reconnectTimerFired` is gone with the backoff curve; re-arming is now an optional cadence
// rather than the mechanism.
