# MacCheck

A calm, read-only diagnostic app for macOS, built first for a MacBook Air (M4) and designed to work on any Apple Silicon Mac.

* **Layout:** a dark, pro-utility window. The sidebar has three tabs: **Tests** (Check Computer plus one test per area), **Tools** (System Overview, App Doctor, Privacy & Settings) and **Reports** (latest report with export, history). The home screen shows five gauges read live from this Mac (processor load, memory, free storage, battery health, macOS thermal pressure), a drawing of the Mac and its specs. There are no temperature or clock-speed gauges, because macOS doesn't expose those through a documented interface.
* **App Doctor:** pick an app, say what's wrong (crashes, freezes, won't open, slow, a permission problem), and get the evidence: crash and hang reports, compatibility, installation integrity, recent log errors and system context. Findings are explained in plain language, with possible explanations clearly marked as such.
* **Check Computer:** battery & power, hardware, performance, thermals, network and storage. Each result says what was measured, what macOS itself reported, what MacCheck calculated, and what isn't available and why.
* **Safe by default:** read-only. The one supported change (moving an app's saved window state to the Trash) needs explicit, informed, single-use consent, can be undone, and is checked afterwards against new evidence.
* **Private:** no telemetry, no upload, identifiers off by default, redacted exports with a review step, local history with retention and a clear button.

> **Status:** everything compiles and the unit tests pass on Linux and a macOS CI runner (and passed on Windows before Swift updated itself to 6.4.3 mid-session), and a live scan works on that runner. Nothing has been run on the real MacBook Air yet, and the SwiftUI app hasn't been opened or checked visually. See [docs/PLAN.md](docs/PLAN.md) and [docs/MAC-TEST-CHECKLIST.md](docs/MAC-TEST-CHECKLIST.md).

## Quick start

**On a Mac** (free command-line tools are enough):
```bash
swift build && swift test
./scripts/build-app.sh          # → dist/MacCheck.app, ad-hoc signed, no paid membership needed
```

**On Windows** (Swift for Windows installed):
```powershell
.\scripts\test-windows.ps1
swift-build.exe --product maccheck-cli
.\.build\out\Products\Debug-windows-x86_64\maccheck-cli.exe --sample
```

## Docs
* [Feasibility, stack, Windows/macOS split, support matrix](docs/FEASIBILITY.md)
* [Architecture](docs/ARCHITECTURE.md)
* [Privacy, permissions, retention, repair safety](docs/PRIVACY.md)
* [Building and private installation](docs/INSTALL.md)
* [macOS test checklist](docs/MAC-TEST-CHECKLIST.md)
* [Plan and status](docs/PLAN.md)

## Known limitations
* No temperatures, fan speeds or throttling percentages: there's no documented API on Apple Silicon, and the Air has no fan.
* SMART "Verified" is the drive's own verdict, not proof of health. SSD wear isn't available.
* Remaining battery time is deliberately not estimated.
* App Doctor can't read which privacy permissions an app has (that needs Full Disk Access), so it gives targeted guidance instead.
* Log errors need an admin account (`log show`). Standard accounts see "unavailable".
* The model-name table covers MacBook Air models; other Macs show their identifier.
