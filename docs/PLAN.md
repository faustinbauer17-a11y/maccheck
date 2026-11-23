# Implementation plan and status

Status key: ✅ done and checked on Windows · 🟡 written, needs a Mac to compile/verify · ⬜ not started

| # | Milestone | Status | Notes |
|---|---|---|---|
| 1 | Repository and feasibility | ✅ | `docs/FEASIBILITY.md`: stack, Windows/macOS split, support matrix |
| 2 | App foundation | ✅ core / 🟡 UI | Typed result model, design tokens, navigation, sample mode. SwiftUI not yet compiled |
| 3 | Diagnostic MVP | ✅ logic / 🟡 collectors | Six interpreters + orchestrator tested with fakes; native collectors written, not compiled |
| 4 | App Doctor and safety | ✅ logic / 🟡 native | Parsers, analyzer, consent gate, verifier, redaction tested; native inspection written |
| 5 | History, export, docs | ✅ logic + docs / 🟡 UI | HistoryStore, export gate, CI, packaging, docs |

## Verified on Windows (2026-11-23)
* `MacCheckCore`, `maccheck-cli` and the app stub build with Swift 6.4.2.
* 72 unit tests pass: interpretation thresholds and honesty rules, orchestration (failure isolation, hard timeouts incl. blocking calls, cancellation, progress order), redaction, parsers (synthetic fixtures), App Doctor rules, consent gating (acknowledgement, binding, expiry, single use), verification, export review gate, identifier exclusion, history retention and clearing.
* `maccheck-cli --sample` renders full reports and a sample App Doctor investigation; live mode correctly refuses off macOS.

## Verified on GitHub Actions `macos-15` (virtual Apple Silicon Mac, macOS 15.8, Swift 6.1)
* The whole package compiles, including `MacCheckMac` and the SwiftUI app; all 73 tests pass (one added after the Windows run); the core tests also pass on Linux.
* `scripts/build-app.sh` produces an ad-hoc signed `MacCheck.app` that passes `codesign --verify --strict` (zipped app uploaded as a CI artifact).
* A live CLI scan ran the native collectors: model, chip, memory, CPU/memory pressure, process list, thermal state, network path, volumes and `diskutil` all returned real values. The VM had no battery, no GPU core count and SMART "Not Supported", and each was reported as unavailable with its reason.
* First CI compile error fixed: `SettingsLink` clashed with SwiftUI's own type (renamed `SystemSettingsLink`).

## Not verified (needs the real MacBook Air)
* Battery and thermal readings on real hardware, App Doctor against real crash reports, `log show` output, Security framework results on third-party apps, the repair flow, the SwiftUI layout and accessibility, and Gatekeeper behaviour for the downloaded zip. See `docs/MAC-TEST-CHECKLIST.md`.

## Next steps
1. Work through the checklist on the MacBook Air; adjust IOKit keys if the M4 reports battery values differently.
2. Replace synthetic fixtures with redacted real reports from the checklist run.
3. Later: UI snapshot tests on macOS, more model identifiers, optional "app uses lots of energy" history comparison.
