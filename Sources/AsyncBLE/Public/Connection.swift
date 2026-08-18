// A live link to one peripheral. Actor-isolated; state escapes only through streams.
//
// Phase 1: `state: AsyncStream<ConnectionState>`, `read`/`write`/`notifications(for:)`,
// `disconnect()`, and the `raw` escape hatch.
