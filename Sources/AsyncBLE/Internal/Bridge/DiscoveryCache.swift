// Lazy service/characteristic discovery, cached per connection.
//
// Hardest part of Phase 2 (PLAN.md §5): concurrent callers asking for the same characteristic
// must coalesce onto one in-flight discovery, not start N of them.
