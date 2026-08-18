// Retry curve as a value type: `.none`, `.exponentialBackoff(...)`, `.custom { attempt in ... }`.
//
// A policy answers one question: given attempt N, how long to wait — or nil to give up.
// Pure and synchronous so the reconnect tests need no clock.
