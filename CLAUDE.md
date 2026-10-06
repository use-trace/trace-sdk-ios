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
- **Nothing is written to the device before consent** (decided 6 October 2026, before the first release). Before an
  answer the first open and every conversion are held in memory only and no install id exists. A grant writes
  `install_id`, `first_open_sent` once the first open has been sent, and the conversion value flags. A refusal writes
  nothing. The consent answer is not stored at all: the host app keeps it and passes it on every launch. A process
  killed before an answer loses what was held, and the next launch records a first open again; that cost was
  accepted. Registering with Apple does not wait, but its flags do, so a launch without a grant registers again.

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
