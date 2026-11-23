# Architecture

```
Sources/
  MacCheckCore/            platform-independent; builds + tests on Windows, Linux, macOS
    Model/                 CheckResult, Finding, Measurement, EvidenceLevel, Reading<T>, snapshots, ModelCatalog
    Collection/            Collector<T> (async closure) + CollectorSet + CollectionOptions
    Interpretation/        Interpret.battery/…/storage: snapshot → CheckResult (pure functions)
    Orchestration/         ScanOrchestrator (sequential, per-check hard deadline, cancellable), withDeadline
    AppDoctor/             models, parsers (.ips/.crash/.hang, Info.plist, Mach-O, log ndjson, diskutil), analyzer, runner
    Repair/                RepairProposal, ConsentGate/ConsentToken, RepairCoordinator, RepairVerifier
    Privacy/               Redactor
    Report/                ReportDraft (review gate), ReportRenderer (md/json/txt), ReportExporter
    Persistence/           HistoryStore (JSON files + retention)
    Sample/                SampleData (labelled sample collectors) + Fake (failing/hanging/blocking test doubles)
  MacCheckMac/             native macOS collectors, App Doctor sources, MacRepairPerformer (all #if os(macOS))
  MacCheckApp/             SwiftUI app (macOS); stub elsewhere
  MacCheckCLI/             maccheck-cli: --sample anywhere, live on macOS
Tests/MacCheckCoreTests/   73 XCTest cases + synthetic fixtures
```

## Data flow

```
Collector (native or fake) ──snapshot──▶ Interpret.* ──CheckResult──▶ ScanOrchestrator ──ScanReport──▶ UI / History / Export
                                                                           ▲
AppDoctorSources (native or sample) ─▶ AppDoctorRunner ─▶ AppDoctorAnalyzer ┘
```

* **Collectors never guess.** Each raw value is a `Reading<T>`: `.value(v, source:)` or `.unavailable(reason:)`.
* **Interpreters are pure** and own every threshold. A check with no measured data is `unavailable`, never "Looks good".
* **Evidence levels** are on every measurement and finding: measured, reported by macOS, calculated, possible explanation (always with a confidence level), or sample.
* **Bounded:** every check runs under `withDeadline`, which returns at the deadline even if a system call blocks and ignores cancellation. A failed or timed-out check becomes `failed` ("says nothing about your Mac") and the scan continues. Cancelling marks the remaining checks as `skipped`.
* **Changes go through one path:** `RepairCoordinator.execute(proposal, token)`. The token comes from `ConsentGate.grant` (side effects must be acknowledged), is bound to one proposal, can be used once and expires after 120 s. `MacRepairPerformer` is the only code that modifies disk, and it can only move `~/Library/Saved Application State/<validated-bundle-id>.savedState` to the Trash after checking the app is quit and the target is a real folder.
* **Exports go through one path:** `ReportDraft` → render (redacted) → user reviews → `markReviewed()` → `ReportExporter.write`. Changing any option clears the review.

## Swapping implementations

`CollectorSet` and `AppDoctorSources` are plain structs of closures. Tests and sample mode pass `SampleData.*` or `Fake.*`; the app and CLI pass `MacPlatform.collectors()` / `MacPlatform.appDoctorSources()` on macOS. To support another Apple Silicon Mac, nothing needs hard-coding: unknown model identifiers fall back to "Mac (Mac17,3)" and "fan presence unknown".
