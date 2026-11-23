# Building and installing (no paid Apple Developer membership)

## Option A: build on the MacBook Air itself (simplest and most trustworthy)

1. Install Apple's free command-line tools: open Terminal and run `xcode-select --install`. Full Xcode from the App Store also works.
2. Copy the `maccheck` folder onto the Mac (USB stick, AirDrop, or `git clone` if you've pushed it).
3. In Terminal:
   ```bash
   cd ~/path/to/maccheck
   swift build            # compile everything
   swift test             # run the unit tests
   ./scripts/build-app.sh # creates dist/MacCheck.app (ad-hoc signed)
   ```
4. Drag `dist/MacCheck.app` into **Applications** and open it.

An app built on the same Mac carries no "downloaded from the internet" flag, so Gatekeeper opens it without a warning. Nothing needs disabling.

## Option B: build in GitHub Actions and copy the app over

1. Push the folder to a GitHub repository (private is fine).
2. The **CI** workflow builds `MacCheck.zip` on a `macos-15` runner. Download it from the run's *Artifacts*.
3. Copy the zip to the MacBook Air and unzip it. Move `MacCheck.app` to Applications.
4. On first open, macOS will say it can't verify the developer, because the app is ad-hoc signed and not notarized.
   * Click **Done** (not "Move to Bin"), then open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to the MacCheck message. Confirm with your password.
   * This is the supported way to allow one specific app you trust. It doesn't turn Gatekeeper off for anything else.

Don't run `xattr -d com.apple.quarantine` or `spctl --master-disable` for this; neither is needed.

## Running without building an app bundle

```bash
swift run MacCheck                                   # launches the SwiftUI app from the build folder
swift run maccheck-cli --no-network                  # live text report in Terminal
swift run maccheck-cli --doctor /Applications/Safari.app --symptom freezes
```

## Why no notarization or paid signing

Notarization and a Developer ID certificate (paid membership) are needed only to distribute to *other people* without the Gatekeeper prompt. For a private build on one or two Macs, ad-hoc signing is enough. The app is not sandboxed, because it needs to read diagnostic reports and run `diskutil`/`log`, and it needs no entitlements.

## Developing on Windows

```powershell
cd path\to\maccheck
.\scripts\test-windows.ps1                         # build + 73 unit tests
swift-build.exe --product maccheck-cli             # then:
.\.build\out\Products\Debug-windows-x86_64\maccheck-cli.exe --sample
```

The Windows build compiles `MacCheckCore` and the CLI. `MacCheckMac` and the SwiftUI app are skipped by `#if os(macOS)` and can only be checked on a Mac or in CI.
