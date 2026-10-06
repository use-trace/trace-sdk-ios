# iOS SDK, slice 1: install registration, conversions and postbacks

> **For agentic workers:** use `superpowers:subagent-driven-development` to implement this plan task by task.

**Goal:** an iOS app registers its install with Apple so that a postback is sent at all, records its first open and
its conversions with Trace, and holds everything until consent is known.

**Architecture:** one Swift package, no third party dependency. A platform neutral core (install id, transport,
consent gate, logger) tested on the Mac with `swift test`, and a thin iOS layer that calls StoreKit's conversion
value APIs behind a protocol so the core can be tested without a device.

**Spec:** `docs/plans/APP_TRACKING.md` in `use-trace/trace`, and `.claude/rules/app-tracking.md` there, which is
binding. The server side that receives Apple's postbacks is `docs/plans/APP_TRACKING_06_IOS_POSTBACKS.md`.

## Read this first: what iOS can and cannot do

**iOS cannot attribute an install to one person.** There is no install referrer on iOS. Campaign attribution comes
only from Apple's SKAdNetwork and AdAttributionKit postbacks, which Apple sends to the server, campaign level, a day
or more later, carrying no identity. So this SDK's first open will always arrive at Trace as direct, and that is
correct, not a bug. The campaign is learned from the postback, separately.

**Apple sends no postback at all unless the app updates the conversion value at least once.** Apple's own words for
the SKAdNetwork update: call it "when the user first launches an app to register the app installation". That single
call is the most important thing this SDK does on iOS. Without it the whole server side receives nothing.

## Global constraints

- British English in code comments, documentation and commit messages. No em dashes or en dashes anywhere.
- Swift 6, a Swift package, minimum iOS 16. No third party dependency of any kind.
- **No advertising identifier, ever.** Do not import `AdSupport` or `AppTrackingTransparency`, do not read the IDFA,
  do not show a tracking prompt. This is published in the customer privacy notice.
- **No hashed email or customer id, and no `identify`.** Decided 11 September 2026; the Android SDK's `identify` was
  removed before release for contradicting it. Read the rule before adding anything that names a person.
- **A visitor identity never appears in a log line.**
- The SDK does four things: persist an install id, send the first open once, send conversions, and hold events until
  consent is known. Plus, on iOS only, register the install with Apple's conversion value API.
- A failing test first, then the implementation.

## Lessons from Android, already decided, do not relearn them

Each of these was found the hard way building the Android SDK. They are requirements here from the start.

| Lesson | Requirement |
| --- | --- |
| The API does not answer 200 | `/v1/event` answers 202 and `/v1/consent` 201. **Success is any 2xx.** A 200 only check reports every send as a failure. |
| A rejected payload is rejected again | Never retry a 4xx. Retry a 5xx or a network failure, three attempts in total. |
| The consent call carries the key | On a grant, send the consent call **before** the held events, with the install id in it. |
| `UNKNOWN` is quarantined on a UK or EU site | Stamp flushed events `GRANTED`, not the `UNKNOWN` they were recorded under. |
| Reporting a refusal must not mint an id | A refusal reads the id without creating one. |
| An empty user agent is a bot | Send `TraceSdkIOS/<version> (iOS <version>)`. |
| A log can leak an identity | Redact at the sink, and make a redaction during normal running fail the tests. |

## Where the install id lives, and why not the Keychain

**Not the Keychain.** Keychain items survive the app being deleted on iOS. It has never been documented either way,
Apple changed it in a 10.3 beta and reverted, and it still held as of iOS 17.5. An install id in the Keychain would
outlive an uninstall, which is exactly what the Android decision forbids: a surviving id makes a reinstall count as
the same install, and silently re-links a person to history they may consider finished.

**Not `UserDefaults` either.** It is deleted with the app but it is backed up, and it cannot be excluded per key.

**A file in Application Support, marked `isExcludedFromBackup`.** The app's container is deleted when the app is,
and the resource value keeps the file out of iCloud and device backups.

## File structure

```
Package.swift
Sources/TraceSDK/
  Trace.swift              the public API, the only file a customer reads
  TraceConfig.swift
  InstallId.swift          a file in Application Support, excluded from backup
  Transport.swift          URLSession, JSON, user agent, retry
  ConsentGate.swift        hold, flush, discard
  Event.swift
  TraceLog.swift           redacts at the sink
  ConversionValue.swift    the protocol, and the StoreKit implementation
Tests/TraceSDKTests/
```

---

### Task 1: the package, and CI that builds it for iOS

`Package.swift` for a library `TraceSDK`, platforms iOS 16 and macOS 13, the macOS platform existing only so the
core tests run on the Mac. A `copy rules` CI job (no em or en dashes), a `swift test` job on the Mac, and a job that
builds for the iOS simulator with `xcodebuild`, so a StoreKit call that compiles on the Mac but not for iOS is
caught. One real test so the test job is proved rather than vacuous.

### Task 2: the install id

`InstallId.get() -> String` and `InstallId.peek() -> String?`. Format `auk_app_` plus 32 lowercase hex from
`UUID()`, matching Android. Stored as a single file in Application Support with `isExcludedFromBackup` set.

Tests: stable across calls; `peek` is nil before `get`; the file is in Application Support; **the backup exclusion
resource value is actually set on the file**, asserted by reading it back, not by trusting the setter. Prove that
last one bites by not setting it and watching it fail.

### Task 3: the transport and the logger

As Android task 4, in Swift with `URLSession`. Every lesson in the table above applies. Test against a local stub,
asserting what arrives on the wire, including the user agent, the api key, `source_type` `app`, `platform` `ios`,
`store` `app_store`, and the install id on events and on the consent call.

### Task 4: the consent gate

As Android task 5. The held queue is a file in Application Support excluded from backup, like the id. Bounded at 100,
oldest dropped first. Removed from disk after a flush and after a discard, asserted on the file. Consent call before
held events, and flushed events stamped `GRANTED`.

### Task 5: registering the install with Apple

**The task that makes postbacks exist.** A `ConversionValueRegistrar` protocol with a StoreKit implementation and a
fake for tests.

- On the first launch, call SKAdNetwork's `updatePostbackConversionValue(_:coarseValue:lockWindow:completionHandler:)`
  on iOS 16.1 and later with a fine value of 0, and on iOS 17.4 and later also AdAttributionKit's
  `Postback.updateConversionValue(_:coarseConversionValue:lockPostback:)`. Guard each with `#available`.
- **This is independent of Trace consent.** It sends nothing to Trace and no identity anywhere: it tells Apple's own
  privacy preserving system that the app launched. Say so in the KDoc equivalent, because a reader will reasonably
  ask whether it needs consent, and the answer should be on the page.
- A conversion raises the value: the first conversion moves the coarse value to `medium`. A host app can set the
  value itself with `Trace.setConversionValue(fine:coarse:)` for its own schema.
- **The per customer conversion value schema is not this slice.** Designing how a customer maps their events onto
  six bits is what the design calls the hardest part, and it is its own plan. This slice guarantees postbacks flow.

Tests against the fake: called exactly once on the first launch, never again; not called on iOS before 16.1 in the
availability logic; a conversion raises the coarse value; a StoreKit error is logged and swallowed, never thrown
into the host app.

### Task 6: the public API

```swift
public enum Trace {
    public static func initialise(_ config: TraceConfig)
    public static func setConsent(analytics: Bool, marketing: Bool)
    public static func conversion(_ name: String, value: Double?, metadata: [String: String])
    public static func setConversionValue(fine: Int, coarse: CoarseValue)
    public static var installId: String? { get }
}
```

No `identify`. `currency` is deliberately absent rather than accepted and ignored: the ingest DTO has no field for
it, and a parameter the server drops is a promise the SDK cannot keep. `installId` is public because a person's
access and erasure rights depend on finding their own identifier, and an app has no browser settings to read one.

The first open is sent once, ever, with a flag in Application Support excluded from backup. Nothing does network
work on the calling thread, and nothing throws into the host app.

### Task 7: end to end, and the README

One test driving the real `Trace` through initialise with consent unknown, a conversion, then a grant, asserting on
the wire: consent first, then the first open, then the conversion, all `GRANTED`, nothing else. And that the install
was registered with the fake registrar exactly once.

The README states plainly: no advertising identifier, no tracking prompt, no hashed email; iOS installs arrive at
Trace as direct and the campaign comes from Apple's postback a day or more later; and the Info.plist keys the
customer must set to the postback domain.

## Known limits, to be written into the README

- An iOS install can never be joined to a person or to the web journey that led to it by this SDK alone.
- The campaign arrives by postback, a day or more after the install, at campaign level.
- A reinstall mints a fresh install id and counts as a new install.
- Offline at the moment consent is granted loses what was held, as on Android.
- The conversion value schema is basic until its own slice.
