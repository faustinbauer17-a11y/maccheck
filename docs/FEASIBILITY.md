# Milestone 1: Feasibility and stack

## What was found (2026-11-23)

| Item | Finding |
|---|---|
| Machine | Windows 11 Home, x86-64. No Mac, no Xcode. |
| Repository | None existed, so MacCheck started as a new standalone folder. |
| Toolchains | Swift 6.4.2 for Windows (installed earlier for SwiftStudio), Git, Python 3.10, Node. No `gh`. |
| Toolchain quirk | During this session `swift.exe` and `swift-test.exe` disappeared from the toolchain's `usr\bin` folder (Windows Defender shows no detection). `swift-build.exe` still works. `scripts/test-windows.ps1` handles both cases. Cause found later: Swift was updating itself to 6.4.3 in the background. After the update finishes, `swift.exe` is back. |
| Apple membership | None (free Apple ID at most). |

## Stack: Swift Package with a native SwiftUI app

| Layer | Choice | Why |
|---|---|---|
| UI | SwiftUI (macOS 14+), dark theme | A native look and feel, built-in accessibility and keyboard support. MacBook Air M4 ships with macOS 15. |
| Platform data | IOKit, sysctl, Mach host statistics, libproc, Network.framework, Security.framework, FileManager, and two Apple command-line tools (`diskutil info`, `log show`) | These are documented, read-only system interfaces with no private APIs. No Full Disk Access is needed. |
| Shared logic | `MacCheckCore` in plain Swift + Foundation | The same language as the app. It **compiles and is unit-tested on Windows** with the Swift toolchain already installed. |
| Build | SwiftPM only (no `.xcodeproj`) | Xcode projects can't reasonably be written or kept up from Windows. On a Mac, `swift build` plus `scripts/build-app.sh` makes an ad-hoc-signed `.app`. Xcode can also open `Package.swift` directly. |
| Dependencies | None | Nothing to pin or audit beyond the Swift toolchain itself. |

Electron, Tauri or a web UI were rejected: the diagnostics need native APIs anyway, and a second language would split the logic away from the Windows-testable core.

## Windows / macOS split

| Work | Windows (this PC) | Needs macOS |
|---|---|---|
| Result model, interpretation thresholds, orchestration, timeouts, cancellation | ✅ build + unit tests | |
| App Doctor analysis, crash-report / log / plist / Mach-O parsing (with synthetic fixtures) | ✅ build + unit tests | Parsing **real** reports |
| Redaction, consent gate, repair verification logic, export, history + retention | ✅ build + unit tests | |
| CLI in sample mode (`maccheck-cli --sample`) | ✅ runs | |
| Native collectors (`Sources/MacCheckMac`) | ❌ excluded by `#if os(macOS)`, **never compiled yet** | ✅ compile + run |
| SwiftUI app (`Sources/MacCheckApp`) | ❌ stub only, **never compiled yet** | ✅ compile + run + visual check |
| Packaging, signing, Gatekeeper behaviour | ❌ | ✅ |

**Update:** the macOS CI runner now compiles everything and a live scan works there (see PLAN.md). Real-hardware checks on the MacBook Air are still pending.

### Realistic routes to native building and testing

1. **The target MacBook Air itself (recommended for real results).** Install the Command Line Tools (`xcode-select --install`, free), copy or clone the folder, then run `swift build`, `swift test` and `./scripts/build-app.sh`. Only this gives real battery, thermal and SMART data for the M4 Air. Do it with the owner present and with their agreement.
2. **GitHub Actions `macos-15` runner** (`.github/workflows/ci.yml`). It compiles everything, runs the tests, does a live CLI smoke run and uploads a zipped `.app`. It's free for public repositories and uses included minutes on private ones. The runner is a virtual Mac, so it has no real battery and its thermal and SMART output isn't representative. It's good for "does it compile and run", not for diagnosing hardware.
3. **A trusted remote Mac** (a friend's, or a rented Apple Silicon host such as a cloud Mac mini). It can compile and run, and its data is real for that machine only. Don't send the owner's diagnostic output to a third-party host.

No paid Developer Program membership is needed for any of these. See `docs/INSTALL.md`.

## What each requested check can and can't do

✅ supported through a documented interface · ⚠️ limited · ❌ not available through appropriate interfaces (shown as "unavailable" with the reason)

| Area | Item | Status | Source / note |
|---|---|---|---|
| Battery | Cycle count, design and full-charge capacity | ✅ | IORegistry `AppleSmartBattery` (read-only properties) |
| | Maximum capacity % | ⚠️ | The macOS figure is used if published, otherwise it is **calculated** and labelled as an estimate |
| | Condition ("Normal" / "Service Recommended") | ⚠️ | IOPS keys vary by macOS version; shown as unavailable when missing |
| | Charge %, charging, power source, adapter watts | ✅ | IOPS power-source API |
| | Remaining time | ❌ by design | Not estimated: the spec forbids promising it |
| | Battery temperature, cell voltages | ❌ | No documented public API |
| Hardware | Model ID, chip, P/E cores, memory, macOS + build, uptime, Rosetta present | ✅ | sysctl, ProcessInfo, uname |
| | GPU name / GPU core count | ✅ / ⚠️ | Metal device name / IORegistry `AGXAccelerator` property where present |
| | Serial number | ✅ opt-in only | IORegistry. Off by default, never stored in history |
| | Marketing name | ⚠️ | No public API. A small table maps known IDs (M4 Air = `Mac16,12` / `Mac16,13`); unknown IDs still work |
| Performance | CPU busy %, load average, memory used/compressed, pressure level, swap | ✅ | Mach host statistics, sysctl |
| | Busiest processes | ⚠️ | libproc. Only processes this user may inspect; names only, never arguments |
| Thermals | Thermal state (nominal / fair / serious / critical), Low Power Mode | ✅ | `ProcessInfo.thermalState` |
| | Fan speed | ❌ / n.a. | The MacBook Air is fanless; there is no public fan API on other Macs either |
| | Temperatures, throttling % | ❌ | No documented API on Apple Silicon. MacCheck says so |
| Network | Connection state, interface type, expensive / Low Data Mode | ✅ | Network.framework `NWPathMonitor` |
| | DNS resolution time | ✅ | `getaddrinfo`, 4 s cap per host |
| | HTTPS reachability / latency, captive-portal hint | ✅ | Ephemeral `URLSession`, one request per disclosed endpoint, can be turned off |
| | Wi-Fi name, signal, passwords | ❌ by design | Not collected (the SSID would also need Location permission) |
| Storage | Volumes, capacity, free space ("important usage") | ✅ | FileManager volume resource keys |
| | SMART status | ⚠️ | `diskutil info -plist /`. "Verified" is the drive's own verdict and **not** proof of health; often unsupported |
| | SSD wear / lifetime | ❌ | Not public for Apple internal storage |
| App Doctor | Crash / hang / resource reports for the user | ✅ | `~/Library/Logs/DiagnosticReports` (.ips JSON + legacy text), last 30 days, max 300 files |
| | Recent errors/faults | ⚠️ | `log show --last 30m` for the app's process (admin users only). Private values are already hidden by macOS |
| | Architecture, min macOS, Rosetta need | ✅ | Info.plist + Mach-O header |
| | Signature validity, notarization, quarantine, translocation, App Store receipt | ✅ / ⚠️ | Security framework (read-only), xattr read, NSRunningApplication. macOS's notarization check uses its own ticket store |
| | Which permissions an app has been granted | ❌ | The TCC database needs Full Disk Access. MacCheck gives guidance and Settings links instead |
| Repair | Move one app's saved window state to the Trash | ✅ consent-gated | Bounded, reversible (Put Back), verified afterwards |
| | Everything else | handoff only | Opens Settings, Finder, Console or Activity Monitor. MacCheck itself changes nothing |
