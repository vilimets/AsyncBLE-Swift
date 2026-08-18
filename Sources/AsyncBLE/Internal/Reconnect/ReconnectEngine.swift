// Turns `scheduleRetry` effects into timed `reconnectTimerFired` events, per ReconnectPolicy.
//
// Owns the retry task so `disconnect()` can cancel it — no zombie retries (PLAN.md §4 edge cases).
