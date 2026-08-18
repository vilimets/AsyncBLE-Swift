// Pure transition function: (state, event) -> (state, [effect]).
//
// Invariant: this file imports Foundation and nothing else. It must not know CoreBluetooth
// exists — that is what makes the whole transition table testable without hardware.
