# Trace iOS SDK

The iOS SDK for Trace (usetrace.io). The server side lives in `use-trace/trace`: ingest in `apps/api/src/tim/`,
and Apple's postbacks in `apps/api/src/attribution-postbacks/`. The design is `docs/plans/APP_TRACKING.md` there.

**Read `.claude/rules/app-tracking.md` in the `trace` repository before writing code here.** It holds the decisions
this SDK must obey, and it is kept current. What follows is the subset that binds this repository.

## Working rules

- British English in comments, documentation and commit messages. No em dashes or en dashes anywhere.
- Direct, plain copy. No marketing language.
- A bug fix ships with a failing test first.
- Never push to `main`. Branch, commit, open a pull request. A green pull request merges itself
  (`.github/workflows/auto-merge.yml`); the `hold` label keeps it back.

## What iOS can and cannot do

- **No install referrer exists on iOS.** A first open always reaches Trace as direct, and that is correct. The
  campaign comes from Apple's postback, separately, a day or more later, at campaign level, with no identity.
- **Apple sends no postback unless the app updates its conversion value at least once.** Registering the install on
  first launch is the most important thing this SDK does.

## Not negotiable

- No advertising identifier. Never import `AdSupport` or `AppTrackingTransparency`.
- No hashed email or customer id, and no `identify`. Decided 11 September 2026.
- **The install id lives in a file in Application Support, excluded from backup. Never the Keychain**: Keychain items
  survive the app being deleted on iOS, so an id there would outlive an uninstall.
- A visitor identity never appears in a log line.
- **No identifier is written to the device before consent** (decided 6 October 2026, before the first release).
  Before an answer the first open and every conversion are held in memory only and no install id exists. A grant
  writes `install_id`, and `first_open_sent` once the first open has been sent. A refusal writes no identifier and
  sends no identifier: with no install id it is reported once, anonymously, with `first_answer` true, so the server
  can count each install's answer once (README, "Counting each answer once"). The
  consent answer is not stored at all: the host app keeps it and passes it on every launch. A process killed before
  an answer loses what was held, and the next launch records a first open again; that cost was accepted.
- **The two Apple files are the exception, stored before consent.** Registering with Apple happens at first launch
  whatever the consent state (decided 6 October 2026), because Apple's postbacks carry no device or user identifier
  and only arrive if the app registered. `install_registered` is an empty file, written as soon as Apple takes the
  registration, so a later launch does not register again and reset the value. `conversion_value` is the conversion
  value schema's record (first launch time, window, whether it converted, its revenue, whether the host app owns the
  value, whether the first consent answer has reached Trace), never sent anywhere. It replaced 0.1.0's empty
  `conversion_value_raised`. Nothing identifying is ever
  written before consent, and nothing else is written before it at all.
- **The conversion value is set from everyone's conversions**, including people who said no and people who never
  answered (decided 7 October 2026, decision 2 of `docs/plans/APP_MODELLED_INSTALLS.md` in `use-trace/trace`). It is
  an open legal question for the adviser. If the adviser says a refusal must stop it, the answer is to set it only
  after a yes (option c there), never to stop it on a no alone (option b), which would bias every campaign quietly.

## The conversion value schema

One schema Trace defines, the same for every app, versioned (decision 8 there). `ConversionValueSchema` in
`ConversionValue.swift` is this side; `apps/api/src/app-reports/conversion-value-schema.ts` in `use-trace/trace` is
the server's, which reads Apple's postbacks by it. Both pass `Tests/TraceSDKTests/conversion-value-vectors.json`, and
the two copies of that file must stay byte for byte the same. A postback does not say which schema produced it, so
version 1 is never edited: a change is a new version, released on a date the server records.

## Lessons from the Android SDK, already paid for

- Success is any 2xx. `/v1/event` answers 202 and `/v1/consent` 201.
- Never retry a 4xx.
- On a consent grant, send the consent call before the held events, with the install id in it.
- Stamp flushed events `GRANTED`, not the `UNKNOWN` they were recorded under, or the server quarantines them.
- Reporting a refusal reads the id without creating one.
- Send a non-empty user agent, or the server treats the event as a bot.

## Building

Needs full Xcode with its licence accepted. The core tests run with `swift test`; the iOS build runs with
`xcodebuild` against the simulator.

CI also checks the rules above (`scripts/check-privacy.sh`) and the public API (`scripts/check-api.sh`, against
`api/TraceSDK.swiftinterface`). After a deliberate change to anything public, run `scripts/check-api.sh --update`
and commit the file with the change.

**The privacy manifest is a statement every customer's app makes to Apple.** `Sources/TraceSDK/PrivacyInfo.xcprivacy`
and the README's "What to declare to the stores" say what leaves the device. Sending a new field, or using a required
reason API, changes both, in the same pull request. `scripts/check-privacy-manifest.py` (in the `privacy` job) fails
on an undeclared required reason API, a value Apple does not list, or a package built without the manifest, and
`everyFieldThatLeavesTheDeviceIsOneTheStoreDeclarationsName` fails on a new field.
