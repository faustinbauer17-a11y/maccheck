# Privacy, permissions and safety

## What MacCheck never does

* No analytics, telemetry, crash reporting or upload of any kind. The only outbound traffic is the optional network check (below).
* No reading of personal file contents, mail, messages, photos or browser data.
* No Wi-Fi network names, passwords, keychain items or other credentials.
* No command-line arguments of other processes (they can contain secrets). Only process names are read.
* No deleting files, clearing caches, quitting processes, changing login items, or touching Gatekeeper, SIP, quarantine flags or other security settings.
* No arbitrary shell commands. Two Apple tools run with fixed arguments, a timeout and an output cap: `diskutil info -plist /` and `log show --style ndjson --last 30m --predicate 'process == "<validated name>" AND (messageType == error OR messageType == fault)'`.

## Permissions

| Access | Requested? | Why |
|---|---|---|
| Full Disk Access | **No** (optional, explained in Settings) | Not needed. It would only add system-wide reports. MacCheck shows what it enables and links to the pane; it never prompts for it. |
| Location, Contacts, Camera, Mic … | No | Not used. |
| Network | Outgoing only, optional | DNS lookup + one small HTTPS request each to `www.apple.com/library/test/success.html` and `one.one.one.one`. Ephemeral session: no cookies or cache. Toggle in Settings → Network check. |
| Admin | No | `log show` works for admin users without `sudo`. For standard users the log step shows as unavailable. |

## Sensitive data handling

* **Identifiers** (serial number): collected only if *Settings → Privacy → Collect serial number* is on. Marked sensitive, **stripped before saving to history**, and left out of exports unless ticked again on the review screen.
* **Other volume names** (e.g. "Anna's Backup") are shown as "Other volume 1" unless identifiers are on.
* **Redaction** (`Redactor`) runs on log excerpts, crash-report hints and every exported report. It hides home-folder user names (`/Users/<user>`), the account name, full name and computer name, emails, IPv4/IPv6 and MAC addresses, UUIDs, labelled serials and crash-reporter keys, `password=`/`token=`/`api_key=`/`Authorization:` values and Bearer tokens, URL query strings, `*.local` host names, and long hex or base64-looking tokens. It is pattern-based, so the review step exists to catch what it misses.
* **Log excerpts** are shown in App Doctor but are excluded from exports by default.
* **Crash reports** are reduced to summary fields (date, kind, version, exception, termination reason, one hint line). Backtraces and binary lists aren't kept.

## History

* Location: `~/Library/Application Support/MacCheck/History/scan-<uuid>.json`.
* Retention: the latest **50** entries and at most **90 days**, applied on every save.
* *History → Clear History…* deletes every `scan-*.json` file MacCheck wrote (after a confirmation). Exported reports elsewhere are not touched.
* To remove everything: delete the `MacCheck` folder above and the app. Settings live in `~/Library/Preferences/local.maccheck.MacCheck.plist`.

## Export

The report is rendered exactly as it will be saved and shown in full. Every option change requires a new "I've reviewed this report" tick. The file goes only where the user picks in the Save panel.

## Repairs

Each change shows the suspected issue (never as certain), the evidence, exactly what will happen, the side effects, how to undo it and how it will be verified. Then a checkbox plus a button named after the action. The confirmation is single-use and expires after 2 minutes. After the change, *Did it help?* compares crash and hang reports dated after the change. It reports "Not enough information yet" until the app has been used again, and never calls the problem fixed. The best it says is "Looks better so far", with a note that this isn't proof.
