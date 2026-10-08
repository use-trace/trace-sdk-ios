# Trace iOS SDK

Install registration, conversions and consent for iOS apps, for [Trace](https://usetrace.io).

The SDK is deliberately small. It does four things, and one more that only iOS needs:

1. Persists an install scoped anonymous key.
2. Sends the first open once.
3. Sends conversions.
4. Holds events until the consent state is known, then sends or discards them.
5. Registers the install with Apple's conversion value API, so that Apple sends Trace a postback for it at all, and
   sets the value from conversions by Trace's conversion value schema. Where consent is required this waits for a
   yes, like everything else (see "Before consent, by region").

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
    .package(url: "https://github.com/use-trace/trace-sdk-ios", from: "0.3.0"),
],
targets: [
    .target(name: "YourApp", dependencies: [.product(name: "TraceSDK", package: "trace-sdk-ios")]),
]
```

Use `0.1.1` or later. `0.1.0` (6 October 2026) sent events to the dashboard's address instead of the API's, where they were answered and lost; `0.1.1` (7 October 2026) sends them to `https://app.usetrace.io/api-proxy`. `0.2.0` adds Trace's conversion value schema and sends the platform with the consent call. `0.3.0` follows the site's region: on a UK or EU site it registers with Apple and sets Apple's conversion value only after a yes, and on any site a no stops the value and removes the Apple files; see "Before consent, by region". Use `0.3.0` or later on a UK or EU app.

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
sends nothing to Trace, which is correct and not a fault. On a UK or EU site it writes nothing at all and tells Apple
nothing; on a US or Other site it writes only the Apple files described below.

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

A grant writes the install id, sends the consent record, then everything held, oldest first, and registers the
install with Apple if it was not registered. A refusal throws away everything held, writes no identifier, stops
Apple's conversion value and removes the two Apple files. If an earlier grant left an install id, a refusal also
sends the consent record, which withdraws that grant. With no install id, the refusal is reported once, with no identifier, so that
Trace can count it (see "Counting each answer once" below). Someone who refuses and later agrees is tracked from the
moment they agreed.

**Call `setConsent` on every launch, from the answer your app stored.** The SDK does not keep the answer: the
consent record belongs to your app, which has to show it, change it and withdraw it.

### Before consent, by region

The SDK follows your site's region in Trace, as the website tracking tag does. At launch it asks Trace, with your api
key, whether the site is consent gated (`GET /v1/snippet-config`), and keeps the last answer only when it is "not
gated".

| Your site's region | Before the person answers | After a yes | After a no, or a withdrawal |
| --- | --- | --- | --- |
| UK and EU, or no region set | Nothing is told to Apple and nothing is written to the device. | The install is registered with Apple, the two Apple files are written, and the value is set from conversions, including any made before the yes in that launch. | Nothing is set, and the two Apple files are removed. |
| US or Other | Five seconds after `initialise`, the install is registered with Apple, the two Apple files are written, and the value is set from conversions, including any made in those five seconds. | Registered at once, if it was not. | Nothing more is set, and the two Apple files are removed. |

If the SDK cannot ask (no network, an older API) and has no earlier "not gated" answer, it treats the site as consent
gated.

On a US or Other site the SDK waits five seconds after `initialise` before registering, whatever the network does, and
applies every call your app made in that time first. So a stored refusal passed within five seconds of `initialise`
(as in "Initialising" above) stops the registration. A refusal that arrives later comes after the registration: Apple
keeps that registration, which a US or Other site allows, and from the refusal on nothing more is set and the two
Apple files are removed. On a UK or EU site nothing is registered before a yes, however late the answer comes.

Registering and setting the value send nothing to Trace and no identity anywhere: they tell Apple's own attribution
system, on the device, that the app launched and what the person did in it, and Apple then reports the campaign at
campaign level, with no identifier for the person, on its own terms. Decided by Dom on 8 October 2026 after legal
advice: registering with Apple and its two files are storage on the device, which needs consent where consent is
required (PECR regulation 6, ePrivacy article 5(3)), and a conversion value is set only for someone who said yes.

**What this costs on a UK or EU site.** Apple sends no postback for an install that never registered, so Apple reports
only the installs of people who said yes within 60 days of installing. Installs from people who said no or never
answered reach neither Trace nor the ad network.

## What is stored on the device, and when

No identifier before the person grants consent. Decided on 6 October 2026, before the first release. On a UK or EU
site, nothing at all before an answer, decided on 8 October 2026.

| When | What the SDK writes, in `Application Support/io.usetrace.sdk`, excluded from backup |
| --- | --- |
| Before an answer, UK and EU site | Nothing. The first open and any conversions are held in memory only, and no install id exists. |
| Before an answer, US or Other site | `site_not_consent_gated`, an empty file, Trace's last answer about the site. `install_registered`, an empty file, once the install is registered with Apple. `conversion_value`, the conversion value schema's record: when the install was registered, which of Apple's windows it is in, whether that window has had a conversion, the window's revenue, and whether your app has set its own value. Never sent anywhere. |
| On a grant | `install_id`, the install id, if there is not one yet. `first_open_sent`, once the first open has been sent. `install_registered` and `conversion_value`, if they were not there. `answer_reported`, an empty file, once Trace has counted this install's first answer. |
| On a refusal or a withdrawal | `install_registered` and `conversion_value` are removed. `answer_reported`, an empty file, once Trace has counted the refusal. No identifier is written. |

### Counting each answer once

Trace works out the share of people who said yes, per platform, from each install's first answer. So every consent
call says whether it is that first answer, and a refusal from an install with no id is reported, once, with nothing
that identifies anyone:

| Consent call | Sent | Fields |
| --- | --- | --- |
| A grant | On every launch | `consent_analytics` true, `consent_marketing`, `anon_user_key`, `timestamp`, `platform` `ios`, `first_answer` |
| A refusal after an earlier grant | On every launch, and it withdraws that grant | as a grant, with `consent_analytics` false |
| A refusal with no install id | Once, until Trace takes it; never again after | `consent_analytics` false, `consent_marketing`, `timestamp`, `platform` `ios`, `first_answer` true. No `anon_user_key` and no other identifier. |

`first_answer` is true on this install's first answer only: a grant that mints the install id when no answer has been
reported before, or the refusal above. Everything later says false. That the first answer has reached Trace is kept
in `answer_reported`, an empty file written after the answer, never before one, like the website banner's record of a
refusal. `0.2.0` kept it in the `conversion_value` record, which a refusal now removes; `0.3.0` still reads it there.

**Neither Apple file holds an identifier.** `install_registered` is empty: its existence says the install was
registered with Apple, so a later launch does not register again and reset the value to fine 0, coarse `low`.
`conversion_value` is what the schema needs to set the value across launches: the revenue of a window is summed over
every launch in it, and the window is worked out from the registration. When they are written is in "Before consent,
by region".

`0.1.0` wrote an empty `conversion_value_raised` file instead of the record. `0.2.0` and later neither write nor read
it. An install registered by `0.1.0` has no record of when it first launched, so the SDK leaves its value as it was.

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

A conversion also sets Apple's conversion value, by Trace's schema, below, when Apple may hear it: after a yes, or
before an answer on a US or Other site, never after a no (see "Before consent, by region"). It never reaches Trace
from the device: Apple sends it in its postback, at campaign level, with no identifier.

If your app's postbacks go to a measurement partner with its own conversion value schema, set the value yourself:

```swift
Trace.setConversionValue(fine: 12, coarse: .high)
```

It follows consent as a conversion does. `fine` must be 0 to 63; anything else is refused with a log line. Once you have set a value the SDK leaves it alone,
in that launch and every later one. Trace reads every postback it receives by its own schema, so do not set your own
value if your postbacks come to Trace. A StoreKit error is logged and never reaches your app.

## Trace's conversion value schema

Version 1, the same for every app. Trace reads Apple's postbacks by it, so it is not configurable, and a change to
it is a new version. The windows are Apple's, counted by the SDK from the registration: window 1 is the first 48
hours, window 2 runs to 7 days, window 3 to 35 days. After 35 days nothing is set. Where registering waits for a yes,
the SDK's windows start at the yes; Apple says its own start at the app's first launch, so for someone who said yes
days later, the SDK's window may be later than Apple's.

- **A conversion** is a `Trace.conversion` call, and its `value` is revenue in your site's currency. A value that is
  missing, zero or negative is a conversion with no revenue: refunds are not subtracted.
- **The fine value, window 1 only.** 0: opened, nothing else. 1: at least one conversion and no revenue. 2: revenue
  above 0 and below 1.00. 3 to 63: revenue at or above each of 61 edges in turn, the R20 preferred numbers from
  1.00 to 1000 (1.00, 1.12, 1.25, 1.40, 1.60 and so on, about 12 per cent apart), so 63 is 1000 and above.
- **The coarse value, every window, from that window's conversions only.** `low`: none. `medium`: at least one.
  `high`: revenue of 4.50 or more.
- **Only ever raised within a window**, and the window is never locked early. A launch in a new window starts it at
  `low`.
- **Not set for AdAttributionKit re-engagement**: on iOS 18 and later every update names the install only.

The edges and test vectors are in `Tests/TraceSDKTests/conversion-value-vectors.json`, which the Trace server shares.

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
<string>https://usetrace-postbacks.com</string>
<key>AttributionCopyEndpoint</key>
<string>https://usetrace-postbacks.com</string>
```

`NSAdvertisingAttributionReportEndpoint` is where SKAdNetwork sends its postback copies, and
`AttributionCopyEndpoint` is where AdAttributionKit sends its copies. **Both are top level keys.** Xcode lists the
second as "AdAttributionKit - Postback Copy URL", but the "AdAttributionKit" there is only a label: there is no
`AdAttributionKit` dictionary, and a key nested inside one is ignored, so no postback copy would arrive and nothing
would say so.

`usetrace-postbacks.com` is Trace's postback domain. Apple uses only the registrable domain and ignores any
subdomain, which is why it is a domain of its own rather than part of usetrace.io.

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
- **No required reason API.** The SDK keeps its files in Application Support, reads whether a flag file exists,
  removes its own files and reads their contents (`Storage.swift`, `ConversionValue.swift`), none of which is on Apple's list; it does not use `UserDefaults`, file timestamps, disk
  space, system boot time or the active keyboards. CI fails if the code starts to use one the manifest does not
  declare (`scripts/check-privacy-manifest.py`).

### What leaves the device

Before a grant, about the person only a refusal, once, with no identifier: that the person said no, their marketing
answer, the time, and that this is iOS (`ConsentGate.swift`, `Transport.swift`). Each launch also asks Trace whether
the site is consent gated, which carries nothing about the person. After `setConsent(analytics: true)`:

| Sent | Where it comes from |
| --- | --- |
| The install id, a random value minted on the grant | `InstallId.swift` |
| What happened: a first open, a purchase or another conversion, and when | `Event.swift`, `Trace.swift` |
| The consent answers, with the install id, that this is iOS and whether this is the install's first answer, and the consent state of each event | `Transport.swift`, `ConsentGate.swift` |
| Your app's version (`CFBundleShortVersionString`), and that this is an iOS app from the App Store | `Trace.swift`, `Event.swift` |
| A conversion's name, value and metadata, as your app passes them | `Trace.swift` |
| The SDK's version and the iOS version, in the user agent | `Transport.swift` |

Like any request, it reaches Trace from the device's IP address. Trace uses that to apply rate limits and the
site's excluded IP list, and does not store it.

The SDK sends no advertising identifier, no vendor identifier, no name, email address or account id, no location,
no contacts, no device model and nothing from other apps. It shows no App Tracking Transparency prompt and needs
none.

Asking Trace whether the site is consent gated sends the api key, the SDK's version and the iOS version, and nothing
about the person (`Transport.swift`). Registering the install with Apple and setting the conversion value
(`ConversionValue.swift`) send nothing to Trace. Apple's own
system sends the campaign to the postback domain later, at campaign level, with no identifier for the person or the
device. That is data Apple collects, so the SDK's manifest does not declare it; Apple's page says you are "not
responsible for disclosing data collected by Apple".

### Answers in App Store Connect

**Do you or your third-party partners collect data from this app?** Yes, once your app grants consent through
`setConsent`. App Store Connect has no answer for "only with consent". Before a grant the SDK sends only a refusal,
once, with no identifier, which is Product Interaction not linked to the user; the row below already declares that
type.

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
- **The conversion value schema is one schema in one currency's numbers.** Its revenue bands run from 1 to 1000 in
  your site's currency, which suits pounds, euros and dollars. In a currency with much smaller units, such as yen,
  most purchases land in the top band.
- **A conversion made before the first unlock after a reboot is left out of the conversion value.** The schema's
  record cannot be read then, so the value stays as it was. It is still sent to Trace, as any conversion is.
- **Before the first unlock after a reboot, the SDK waits.** iOS keeps the install id encrypted until the phone has
  been unlocked once since it started. An app launched in the background before then, by a push notification or a
  background refresh, finds the id and cannot read it. The SDK then sends nothing and mints nothing, because a new
  id would count one install twice, and the calls made meanwhile run, in order, on the first call after the phone
  is unlocked. They are kept in memory only, so if the app is ended before then, they are lost. On a US or Other
  site, registering the install with Apple is not affected.
- **On a UK or EU site, Apple reports only the people who said yes.** Apple sends no postback for an install that
  never registered, and registering waits for a yes, so installs from people who said no or never answered are
  reported to neither Trace nor the ad network that showed the ad. Apple gives the app 60 days after the install to
  register.
- **A refusal is counted once by an empty file.** `answer_reported` is written after Trace has counted the install's
  first answer, a refusal included, so the share who said yes counts each install once. It holds nothing.

## Licence

Apache License, Version 2.0. See `LICENSE`.
