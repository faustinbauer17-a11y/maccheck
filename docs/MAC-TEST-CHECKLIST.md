# macOS test checklist

Everything here is **pending** until it's done on a real Mac. Ideally that's the MacBook Air M4, with its owner's agreement. Tick items as they pass and note the macOS version.

macOS version tested: ______  Model: ______  Date: ______

## 1. Build
- [ ] `swift build` succeeds (first compile of `MacCheckMac` and `MacCheckApp`; expect small fixes)
- [ ] `swift test` passes (same 73 tests as on Windows)
- [ ] `./scripts/build-app.sh` produces `dist/MacCheck.app`; `codesign --verify --strict` passes
- [ ] The app opens from Applications with no Gatekeeper prompt (built locally)

## 2. Six areas: compare with System Settings / System Information / Activity Monitor
| Check | Compare against | OK? |
|---|---|---|
| Battery cycle count | System Information → Power → Cycle Count | [ ] |
| Battery maximum capacity (estimated vs. macOS) | System Settings → Battery → ⓘ Battery Health | [ ] note the difference: ____ |
| Battery condition shown, or honestly "not available" | same | [ ] |
| Charging / adapter watts with and without the charger | menu bar battery icon | [ ] |
| Model "MacBook Air (13-inch or 15-inch, M4, 2025)", chip, cores, memory | About This Mac / System Information | [ ] |
| GPU core count shown or "not exposed" | System Information → Graphics | [ ] |
| Serial number appears **only** after enabling it in Settings, absent from History JSON | `~/Library/Application Support/MacCheck/History` | [ ] |
| CPU busy % plausible while idle / while exporting a video | Activity Monitor → CPU | [ ] |
| Memory used and pressure level | Activity Monitor → Memory | [ ] |
| Busy processes list shows names only | Activity Monitor | [ ] |
| Thermal: "No fan to report" on the Air; state Nominal at rest | n/a | [ ] |
| Low Power Mode toggles the finding | System Settings → Battery | [ ] |
| Network: Wi-Fi connected; DNS + HTTPS times shown | n/a | [ ] |
| Network with Wi-Fi off → "No network connection", probes skipped | n/a | [ ] |
| Network probes off in Settings → shown as unavailable, no traffic (check with Little Snitch/LuLu if available) | n/a | [ ] |
| Storage: free space matches Settings → General → Storage (within purgeable differences) | n/a | [ ] |
| SMART: "Verified" or honest "not available"; text says it's not proof | `diskutil info /` | [ ] |
| Scan finishes in under ~20 s; Cancel works mid-scan | n/a | [ ] |

## 3. App Doctor
- [ ] App list loads in a few seconds; running apps are marked; "Choose Other App…" works
- [ ] A real crash report is parsed. Test app: an app you're happy to crash, or Xcode → a tiny app calling `fatalError()`. Count, date, exception and explanation are shown
- [ ] Real `.ips` fields match `Console → Crash Reports` (spot check)
- [ ] Hang reports (if any exist) are counted
- [ ] Intel-only app (if available) → Rosetta finding
- [ ] App opened directly from Downloads → translocation finding
- [ ] Signature: Apple app = "Valid (Apple)"; a third-party notarized app = "notarized"
- [ ] Log step: errors appear redacted; for a standard (non-admin) user it shows "unavailable", not an error
- [ ] Permission symptom → Settings buttons open the right Privacy panes (deep links can change between macOS versions)
- [ ] No Full Disk Access prompt at any time

## 4. Repair + verification
- [ ] "Reset saved windows" only offered for crashes / won't open when a `.savedState` folder exists
- [ ] Button disabled until the checkbox is ticked
- [ ] With the app running → refused with "Please quit the app first"
- [ ] After confirming: the folder is in the Trash and **Put Back** restores it
- [ ] "Check now" without using the app → "Not enough information yet"
- [ ] After using the app without crashes → "Looks better so far" with the "not proof" note

## 5. Export, history, accessibility
- [ ] Review sheet shows the full text; Save is disabled until reviewed; changing an option un-ticks it
- [ ] Exported file contains no user name, email, serial or local host name (search the file)
- [ ] History lists scans; deleting one and Clear History work; other files in the folder survive
- [ ] Keyboard only: Tab through sidebar, buttons, sheets; ⌘R runs a scan; Esc closes sheets
- [ ] VoiceOver reads status pills as "Status: Attention" etc.
- [ ] Window resizes down to 880×600 without clipped controls
- [ ] Sample mode: yellow banner everywhere, sample reports named `MacCheck-SAMPLE-…`
