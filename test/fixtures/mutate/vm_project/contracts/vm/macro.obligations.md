---
modules: [Vm.MacroBuilder]
---
# vm.macro

## Purpose

Check mutation of macro expansion in direct and transitive callers.

### vm.macro.I1 — Generated functions keep their values
- **scope:** `Vm.MacroBuilder.__using__/1`
- **must:** Generate an enabled?/0 function that returns true.
- **kind:** functional
- **status:** active

### vm.macro.I3 — Compiled test values use the current expansion
- **scope:** `Vm.MacroBuilder.__using__/1`
- **must:** Values retained when a test module compiles must use the current macro expansion.
- **kind:** functional
- **status:** active

### vm.macro.I2 — Private macros affect transitive callers
- **scope:** `Vm.MacroBuilder.__using__/1`
- **must:** Generate an answer/0 macro that expands to 42.
- **kind:** functional
- **status:** active
