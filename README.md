# Trace iOS SDK

Install registration, conversions and consent for iOS apps, for [Trace](https://usetrace.io).

The SDK is deliberately small. It does four things, and one more that only iOS needs:

1. Persists an install scoped anonymous key.
2. Sends the first open once.
3. Sends conversions.
4. Holds events until the consent state is known, then sends or discards them.
5. Registers the install with Apple's conversion value API on the first launch, so that Apple sends Trace a
   postback for it at all.

It does not do screen views, session tracking, automatically collected events, funnels or crash reporting.

**No advertising identifier, no tracking prompt, no hashed email.** The SDK does not import `AdSupport` or
`AppTrackingTransparency`, never reads the IDFA, and never shows the App Tracking Transparency prompt. There is no
method for passing an email address, a hash of one, a customer id or an account id, and the SDK collects none
itself. The install id is a random value with nothing of the device in it, so two installs of your app on one phone
are two unrelated installs as far as Trace is concerned.

## What you need

- iOS 16 or later. Registering the install with Apple needs iOS 16.1 (SKAdNetwork) and, for AdAttributionKit,
  iOS 17.4. On iOS 16.0 everything else works and nothing is registered.
- Your site's api key, from the Trace dashboard under the site's settings.
- No third party dependency. The SDK uses Foundation, StoreKit and AdAttributionKit only.

## Adding the package

In Xcode, File, Add Package Dependencies, and enter `https://github.com/use-trace/trace-sdk-ios`. Or in a
`Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/use-trace/trace-sdk-ios", from: "0.1.0"),
],
targets: [
    .target(name: "YourApp", dependencies: [.product(name: "TraceSDK", package: "trace-sdk-ios")]),
]
```

`0.1.0` is the first release, tagged on 6 October 2026.

## Initialising

Call `Trace.initialise` once, as early in the launch as you can, then tell it what the person answered.

```swift
import SwiftUI
import TraceSDK

@main
struct MyApp: App {

    init() {
        Trace.initialise(TraceConfig(apiKey: "trace_your_site_key"))

        // On every launch, from whatever your app stored when the person answered your consent banner.
        if let answer = ConsentStore.saved {
            Trace.setConsent(analytics: answer.analytics, marketing: answer.marketing)
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

With a `UIApplicationDelegate`, the same two calls go in `application(_:didFinishLaunchingWithOptions:)`.

Every call returns at once. The work runs afterwards on the SDK's own tasks, one at a time and in the order you made
the calls, so nothing does network work on the calling thread and nothing throws into your app. Calling
`initialise` a second time does nothing. A call made before `initialise` does nothing and says so in the log.

`TraceConfig` takes three things and has nothing else to configure:

| Parameter | Default | What it is |
| --- | --- | --- |
| `apiKey` | required | The site's api key, sent as `x-trace-api-key`. |
| `apiURL` | `https://app.usetrace.io/api-proxy` | Where to send. Change it only for a self hosted deployment. |
| `debugLogging` | `false` | Whether the SDK writes what it is doing to the unified log, subsystem `io.usetrace.sdk`. |

`debugLogging` never writes an install id or an event's contents, whatever it is set to: anything shaped like an
identity is removed where the line is written.

## Consent

**Nothing is sent to Trace and no identifier is stored until you call `setConsent`.** Until then every event,
including the first open, is held in memory and sent to nobody, and no install id exists. An app that never calls it
sends nothing to Trace and writes only the two Apple flags described below, which is correct and not a fault.

Wire it to your own consent interface, on the answer:

```swift
func consentBannerAnswered(analytics: Bool, marketing: Bool) {
    ConsentStore.save(analytics: analytics, marketing: marketing)
    Trace.setConsent(analytics: analytics, marketing: marketing)
}
```

- `analytics` decides whether anything is sent.
- `marketing` goes to Trace for the consent record and decides nothing here, so `analytics: false` discards what was
  held whatever `marketing` says.

A grant writes the install id, sends the consent record, then everything held, oldest first. A refusal throws away
everything held and writes nothing. If an earlier grant left an install id, a refusal also sends the consent record,
which withdraws that grant; with no install id there is nothing to withdraw and nothing is sent. Someone who refuses
and later agrees is tracked from the moment they agreed.

**Call `setConsent` on every launch, from the answer your app stored.** The SDK does not keep the answer: the
consent record belongs to your app, which has to show it, change it and withdraw it.

Registering the install with Apple does not wait for consent. It sends nothing to Trace and no identity anywhere:
it tells Apple's own privacy preserving attribution system, on the device, that the app launched, and Apple then
reports the campaign at campaign level, with no identifier for the person, on its own terms. The SDK's record that
it has done so is two empty files, written whatever the person answers; see the next section for why.

## What is stored on the device, and when

No identifier before the person grants consent. Decided on 6 October 2026, before the first release.

| When | What the SDK writes, in `Application Support/io.usetrace.sdk`, excluded from backup |
| --- | --- |
| Whatever the answer, and before one | `install_registered` and `conversion_value_raised`, empty files recording what the SDK has told Apple, as they become true. |
| Before an answer | Nothing else. The first open and any conversions are held in memory only, and no install id exists. |
| On a grant | `install_id`, the install id, if there is not one yet. `first_open_sent`, once the first open has been sent. |
| On a refusal | Nothing else. No identifier is written. |

**The two Apple flags are stored before consent, and they hold no identifier.** Each is an empty file: its existence
is all it says, that the install was registered with Apple, or that the conversion value has been raised past that.
They are stored so that a later launch does not register again. Registering sets the value to fine 0, coarse `low`,
so doing it on every launch would undo the `medium` a conversion set, and any value your app set with
`setConversionValue`. Apple's postbacks carry no device or user identifier, and they only arrive if the app
registered, so registering happens at first launch whatever the person answers.

The SDK does not store the consent answer. Your app does, and passes it to `setConsent` on every launch.

## Sending a conversion

```swift
Trace.conversion("purchase", value: 29.99, metadata: [:])

Trace.conversion("subscription", value: 9.99, metadata: ["plan": "plus", "trial": "false"])

Trace.conversion("signup", value: nil, metadata: [:])
```

`name` is your own name for the outcome and is what a conversion rule in the Trace dashboard matches on. `purchase`,
in any case, is sent as a purchase so that it reports as revenue. Everything else is a custom conversion. A blank
name sends nothing.

`value` is the amount in the currency your site is configured with in Trace. There is no currency parameter, because
Trace has no per conversion currency and a parameter it dropped would be misleading.

`metadata` is anything else worth keeping with the conversion. Trace keeps keys of letters, digits and underscores,
up to fifty of them, and drops the rest, so the SDK logs which of yours it will drop. Put nothing identifying in it.

The first conversion also raises Apple's coarse conversion value to `medium`, so a postback can tell installs that
converted from installs that did not. If you have your own conversion value schema, set the value yourself:

```swift
Trace.setConversionValue(fine: 12, coarse: .high)
```

`fine` must be 0 to 63; anything else is refused with a log line. Once you have set a value the SDK leaves it alone.
A StoreKit error is logged and never reaches your app.

## The install id, for a privacy screen

```swift
Text(Trace.installId ?? "No identifier yet")
```

A person asking what Trace holds about them, or asking for it to be deleted, needs their identifier first, and an
app has no browser settings to look in. So show it on your privacy screen. It is nil before `initialise`, nil
until the person has granted consent, and nil before the phone's first unlock after a reboot. Reading it creates
nothing and sends nothing. Show it to the person it belongs to; do not log it or send it anywhere else.

The id lives in one file in your app's Application Support directory, excluded from backup, never in the Keychain:
Keychain items survive the app being deleted, and the id must not.

## The Info.plist keys for Apple's postbacks

Apple sends the install's campaign to Trace by postback, not through the SDK, and only to a domain your app names in
its `Info.plist`. Add both keys:

```xml
<key>NSAdvertisingAttributionReportEndpoint</key>
<string>https://TRACE-POSTBACK-DOMAIN-NOT-YET-CHOSEN.example</string>
<key>AttributionCopyEndpoint</key>
<string>https://TRACE-POSTBACK-DOMAIN-NOT-YET-CHOSEN.example</string>
```

`NSAdvertisingAttributionReportEndpoint` is where SKAdNetwork sends its postback copies, and
`AttributionCopyEndpoint` is where AdAttributionKit sends its copies. **Both are top level keys.** Xcode lists the
second as "AdAttributionKit - Postback Copy URL", but the "AdAttributionKit" there is only a label: there is no
`AdAttributionKit` dictionary, and a key nested inside one is ignored, so no postback copy would arrive and nothing
would say so.

**The domain above is a placeholder. Trace's postback domain has not been chosen yet**, and this README will name it
when it has. Apple uses only the registrable domain and ignores any subdomain, so it will be a domain of its own.
Until it is set, the SDK still registers the install with Apple, but no postback reaches Trace.

## What to declare to the stores

This is what the SDK itself collects, for whoever answers the App Privacy questions in App Store Connect. **Your
own app, and every other SDK in it, may collect more.** Declare that as well: the answers below are the part this
SDK adds, not the whole of your app's label. They follow Apple's definitions as read on 6 October 2026, in
[App privacy details on the App Store](https://developer.apple.com/app-store/app-privacy-details/).

### The privacy manifest

The package ships a privacy manifest, `Sources/TraceSDK/PrivacyInfo.xcprivacy`, as a resource of the `TraceSDK`
target, so you add nothing. Xcode includes it when you archive your app and choose Generate Privacy Report, which is
the report to check your answers against. It says:

- **No tracking**, and no tracking domains.
- **Collected:** Device ID, Product Interaction and Purchase History, each linked to the user, none used for
  tracking, all for Analytics. The reasons are in the table below.
- **No required reason API.** The SDK keeps its files in Application Support and reads only whether a flag file
  exists (`Storage.swift`), which is not on Apple's list; it does not use `UserDefaults`, file timestamps, disk
  space, system boot time or the active keyboards. CI fails if the code starts to use one the manifest does not
  declare (`scripts/check-privacy-manifest.py`).

### What leaves the device

Nothing, until your app calls `setConsent(analytics: true)` (`ConsentGate.swift`). After that:

| Sent | Where it comes from |
| --- | --- |
| The install id, a random value minted on the grant | `InstallId.swift` |
| What happened: a first open, a purchase or another conversion, and when | `Event.swift`, `Trace.swift` |
| The consent answers, with the install id, and the consent state of each event | `Transport.swift`, `ConsentGate.swift` |
| Your app's version (`CFBundleShortVersionString`), and that this is an iOS app from the App Store | `Trace.swift`, `Event.swift` |
| A conversion's name, value and metadata, as your app passes them | `Trace.swift` |
| The SDK's version and the iOS version, in the user agent | `Transport.swift` |

Like any request, it reaches Trace from the device's IP address. Trace uses that to apply rate limits and the
site's excluded IP list, and does not store it.

The SDK sends no advertising identifier, no vendor identifier, no name, email address or account id, no location,
no contacts, no device model and nothing from other apps. It shows no App Tracking Transparency prompt and needs
none.

Registering the install with Apple at first launch (`ConversionValue.swift`) sends nothing to Trace. Apple's own
system sends the campaign to the postback domain later, at campaign level, with no identifier for the person or the
device. That is data Apple collects, so the SDK's manifest does not declare it; Apple's page says you are "not
responsible for disclosing data collected by Apple".

### Answers in App Store Connect

**Do you or your third-party partners collect data from this app?** Yes, once your app grants consent through
`setConsent`. App Store Connect has no answer for "only with consent".

| Data type | What the SDK sends | Linked to the user | Used for tracking | Purpose |
| --- | --- | --- | --- | --- |
| Identifiers: Device ID | The install id | Yes | No | Analytics |
| Usage Data: Product Interaction | The first open, and each conversion with its name and metadata | Yes | No | Analytics |
| Purchases: Purchase History | A conversion's value, and a conversion named `purchase` | Yes | No | Analytics |

Leave out Purchase History only if your app never passes a value and never records `purchase`.

**Linked to the user**, because every one of them is sent with the install id. That id is a pseudonymous
identifier, which is personal data under UK and EU GDPR, and Apple counts personal data as linked.

**Not used for tracking**, because Apple's tracking means combining data from your app with data from other
companies' apps or websites for advertising, or passing it to a data broker. Trace keeps what your app sends to
your own account, combines it with nothing from other companies, and sells it to nobody, and the SDK reads no
advertising identifier.

**Analytics** is the purpose: Trace uses the data to report which campaigns and channels brought installs and
conversions. It is not used to show ads or send marketing, so neither advertising purpose applies.

Anything your app puts in a conversion's metadata is collected too. Put nothing identifying in it; if you do, it has
to be declared as well.

## Known limits

- **An iOS install arrives at Trace as direct.** iOS has no install referrer, so the first open cannot say which
  campaign produced it. The campaign comes from Apple's postback, separately, a day or more after the install, and
  at campaign level only.
- **An install can never be joined to a person.** Apple's postbacks carry no identity, and the SDK takes none, so
  neither this SDK nor Trace can join an iOS install to the person or the web journey that led to it.
- **A reinstall counts as a new install.** The id does not survive the app being deleted, by design, so a
  reinstall mints a fresh one.
- **An app ended before the person answers loses what was held.** The held first open and conversions are not
  stored before consent, only kept in memory. The next launch finds no first open flag and records a first open
  again, with that launch's time, so the install is still reported once the person agrees.
- **Offline at the moment consent is granted loses what was held.** The SDK tries each send three times and then
  gives up, and nothing a grant flushed is kept, including the first open. A queue that outlived the answer would be
  sent again by some later launch, and a duplicated install is harder to see than a missing one.
- **The conversion value schema is basic.** The install is registered and the first conversion raises the coarse
  value to `medium`, nothing more. Mapping your own events onto Apple's six bit fine value is its own piece of work;
  until then use `setConversionValue` for your own schema.
- **Before the first unlock after a reboot, the SDK waits.** iOS keeps the install id encrypted until the phone has
  been unlocked once since it started. An app launched in the background before then, by a push notification or a
  background refresh, finds the id and cannot read it. The SDK then sends nothing and mints nothing, because a new
  id would count one install twice, and the calls made meanwhile run, in order, on the first call after the phone
  is unlocked. They are kept in memory only, so if the app is ended before then, they are lost. Registering the
  install with Apple is not affected.
