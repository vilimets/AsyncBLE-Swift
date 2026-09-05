# Contributing to AsyncBLE

Thanks for the interest. AsyncBLE is a deliberately small library with a fixed scope, so please
read the scope contract before opening a pull request.

## Scope first

The README's [Roadmap](README.md#roadmap) lists what is planned for later, and
[Non-goals](README.md#non-goals) lists what will never be added. A pull request implementing
something from Non-goals will be closed with a pointer to that section — not because the idea is
bad, but because keeping the surface small is the point of this library. Roadmap items are
welcome, but open an issue first so we agree on the shape.

Open an issue before writing code for anything larger than a bug fix.

## Requirements

- Xcode 16 or newer
- iOS 16+ deployment target
- Swift 5.9+ (Swift Package Manager only)

## Building and testing

```bash
xcodebuild build -scheme AsyncBLE -destination 'platform=iOS Simulator,name=iPhone 16'
xcodebuild test  -scheme AsyncBLE -destination 'platform=iOS Simulator,name=iPhone 16'
swiftlint lint --strict
```

Tests use [swift-testing](https://github.com/swiftlang/swift-testing), not XCTest.

Documentation lives in `Sources/AsyncBLE/AsyncBLE.docc`. Build it, and check that it builds
without warnings, with:

```bash
xcodebuild docbuild -scheme AsyncBLE -destination 'platform=iOS Simulator,name=iPhone 16'
```

In Xcode, Product > Build Documentation opens the result in the documentation window.

## Architectural invariants

These are enforced in review. A pull request that breaks one will not be merged.

1. No CoreBluetooth type appears in a public signature, except inside `Connection.raw`.
   `CBUUID` is the single documented exception: it is a value type used as an identifier.
   Characteristic positions spell it `CharacteristicID`, a typealias, so that consumers need
   no CoreBluetooth import; service positions keep Apple's name.
2. The state machine is pure. It imports Foundation and nothing else, takes an event, and
   returns a state plus effects. This is what makes it testable without hardware.
3. All state transitions flow through the state machine. The delegate bridge translates
   CoreBluetooth callbacks into events; it never assigns state itself.
4. `Connection` is an actor. State escapes only through async streams. No public completion
   handlers anywhere.

## Code standards

- Every public declaration gets a doc comment when it is written, not later.
- A state machine change and its test land in the same commit.
- Conventional commit subjects: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`.
- Keep pull requests small and focused on one thing.

## Verifying CoreBluetooth behavior

CoreBluetooth has plenty of undocumented edge behavior, and AI assistants hallucinate confidently
about it. If a change depends on how CoreBluetooth behaves, cite the Apple documentation or
describe the device test you ran.
