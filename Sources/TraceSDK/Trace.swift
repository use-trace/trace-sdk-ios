import Foundation
import os

/// Trace for iOS. This is the whole public surface.
///
/// ```swift
/// Trace.initialise(TraceConfig(apiKey: "trace_your_site_key"))
/// // On every launch, from whatever the app stored when the person answered its consent banner.
/// Trace.setConsent(analytics: consent.analytics, marketing: consent.marketing)
/// ```
///
/// **It does four things, and one more on iOS.** It persists an install scoped anonymous key, sends the first open
/// once, sends conversions, and holds everything until the app says what the person answered. And it registers the
/// install with Apple's conversion value API, without which Apple sends no postback at all: on a consent gated site
/// (UK and EU, or no region) once the person says yes, and on a US or Other site at first launch unless they said no.
///
/// **No advertising identifier, no tracking prompt, no hashed email.** It does not import `AdSupport` or
/// `AppTrackingTransparency`, and there is no way to pass it an email, a hash of one or a customer id.
///
/// **No method throws into the host app, and no method does network work on the calling thread.** Every call
/// returns at once; the work runs afterwards on the SDK's own tasks, one at a time, in the order the calls were
/// made, so a conversion can never overtake the consent call that has to go before it. A call before
/// ``initialise(_:)`` does nothing and says so in the log.
///
/// **No identifier is written to the device before consent.** Before the person has answered, the first open and
/// every conversion are held in memory only, and no install id exists. A grant writes the install id, and the first
/// open flag once the first open has been sent. A refusal writes no identifier. On a consent gated site nothing at
/// all is written before an answer. On a US or Other site the two files recording what the SDK has told Apple, the
/// registration flag and the conversion value record, are written at first launch, with the site's answer; none
/// holds an identifier. An app killed before an answer loses what was held, and its next launch records a first open
/// again.
///
/// **Before the first unlock after a reboot it waits.** An app launched in the background then, by a push or a
/// background refresh, finds the install id's file and cannot read it, because iOS has not decrypted it yet. The SDK
/// then sends nothing and mints nothing, because a new id would make one install two, and the calls made meanwhile
/// run, in order, on the first call after the phone has been unlocked. Nothing is kept on disk for them, so if the
/// app is killed first they are lost.
public enum Trace {

    private static let client = OSAllocatedUnfairLock<TraceClient?>(initialState: nil)

    /// Starts the SDK and records the first open. Call it once, as early in the launch as the app can, before
    /// ``setConsent(analytics:marketing:)``. A second call does nothing.
    ///
    /// The first open is held in memory with everything else until ``setConsent(analytics:marketing:)`` says what the
    /// person answered, and it is sent once, ever. An app that never calls it sends nothing and stores nothing, which
    /// is correct rather than a bug.
    ///
    /// It asks the site, with the api key, whether it is consent gated, as the website tag does. On a gated site, or
    /// when there is no answer and none kept from before, registering with Apple waits for a grant. On a site that is
    /// not gated it happens at first launch, after any answer the app passes straight after this call, so a refusal
    /// passed then comes first.
    public static func initialise(_ config: TraceConfig) {
        #if os(iOS)
        let registrar = StoreKitRegistrar()
        #else
        let registrar = NoRegistrar()
        #endif
        initialise(config, directory: Storage.defaultDirectory, session: Transport.defaultSession,
                   registrar: registrar, log: TraceLog(enabled: config.debugLogging))
    }

    /// Records what the person answered, which is what lets anything be sent at all.
    ///
    /// `analytics` decides whether events are sent. `marketing` goes to Trace for the consent record and decides
    /// nothing here, so `analytics: false` discards what was held whatever `marketing` says.
    ///
    /// A grant writes the install id if there is none yet, sends the consent record, then everything held, oldest
    /// first, and registers with Apple if it has not. A refusal throws away everything held, stops Apple's value and
    /// removes the two Apple files; when an earlier grant left an install id, it also sends the consent record, which
    /// withdraws that grant. **Call it on every launch**, from the
    /// answer the app stored: the SDK does not keep the answer, because the consent record is the app's to show,
    /// change and withdraw, and two copies of it would disagree.
    public static func setConsent(analytics: Bool, marketing: Bool) {
        current("setConsent")?.setConsent(analytics: analytics, marketing: marketing)
    }

    /// Sends one conversion. `name` is the app's own name for it, which a conversion rule in the Trace dashboard
    /// matches on; `purchase`, in any case, is sent as a purchase so that it reports as revenue. A blank name sends
    /// nothing.
    ///
    /// `value` is the amount in the currency the site is configured with in Trace. There is no currency parameter:
    /// the server has no field for one, and a parameter it drops would be a promise this SDK cannot keep.
    ///
    /// `metadata` is anything else worth keeping with it. The server keeps keys of letters, digits and underscores,
    /// up to 50, and drops the rest, so the log says which it will drop. Put nothing identifying in it.
    ///
    /// Held while consent is unknown, dropped if it was refused, sent otherwise. It also sets Apple's conversion value
    /// by Trace's schema (``ConversionValueSchema``), unless the app has set its own value: after a grant, or before an
    /// answer on a site that is not gated, never after a refusal. On a gated site a conversion before the answer
    /// sets the value when the person says yes.
    public static func conversion(_ name: String, value: Double?, metadata: [String: String]) {
        current("conversion")?.conversion(name, value: value, metadata: metadata)
    }

    /// Sets Apple's conversion value, for an app whose postbacks go to a measurement partner with its own schema. From
    /// then on the SDK leaves the value alone, in every later launch too. Trace reads every postback it receives by
    /// its own schema, so an app whose postbacks come to Trace should not call this.
    ///
    /// `fine` is 0 to 63; anything else is refused with a log line rather than passed to StoreKit to throw. It goes
    /// to SKAdNetwork on iOS 16.1 and later and to AdAttributionKit on iOS 17.4 and later.
    ///
    /// **It follows consent like a conversion does**: after a grant, or before an answer on a site that is not gated,
    /// never after a refusal. A StoreKit error is logged and never reaches the app.
    public static func setConversionValue(fine: Int, coarse: CoarseValue) {
        current("setConversionValue")?.setConversionValue(fine: fine, coarse: coarse)
    }

    /// The identifier Trace holds for this install, or nil when there is not one yet.
    ///
    /// **Public because a person's rights depend on it.** Someone asking what Trace holds about them, or asking for
    /// it to be deleted, has to find their identifier first, and an app has no browser settings to look in, so the
    /// app shows it on its own privacy screen. Nil before ``initialise(_:)``, nil until the person has granted
    /// consent, and nil before the first unlock after a reboot. Reading it creates nothing and sends nothing.
    ///
    /// It is a visitor identity: show it to the person it belongs to, and do not log it or send it anywhere else.
    public static var installId: String? {
        client.withLock { $0 }?.installId
    }

    // The injectable form, so a test can drive the real thing against a stub server and a fake registrar.
    static func initialise(_ config: TraceConfig, directory: URL, session: URLSession,
                           registrar: any ConversionValueRegistrar, log: TraceLog) {
        if config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            log.log("Trace.initialise was given a blank api key, so nothing was started")
            return
        }
        let started: TraceClient? = client.withLock { current in
            guard current == nil else { return nil }
            current = TraceClient(directory: directory,
                                  sender: Transport(apiKey: config.apiKey, apiURL: config.apiURL, session: session, log: log),
                                  registrar: registrar, log: log)
            return current
        }
        guard let started else {
            log.log("Trace.initialise was called again, and the SDK was already started, so this call did nothing")
            return
        }
        started.launch()
    }

    private static func current(_ method: String) -> TraceClient? {
        guard let current = client.withLock({ $0 }) else {
            TraceLog(enabled: true).log("Trace.\(method) was called before Trace.initialise, so it did nothing")
            return nil
        }
        return current
    }

    /// Waits for everything called so far. Tests only.
    static func idleForTest() async {
        await client.withLock { $0 }?.idle()
    }

    /// Waits for everything called so far, then forgets the client, which is what a process ending does. Tests only.
    static func resetForTest() async {
        await client.withLock { $0 }?.idle()
        client.withLock { $0 = nil }
    }
}

/// Everything ``Trace`` does, as an instance, so the tests can make several.
///
/// **One piece of work at a time, in the order called.** Each public call is a task that waits for the one before
/// it. That is what keeps a conversion behind the consent call it must follow, and it is also why the state here
/// needs no lock: only one task is ever inside.
actor TraceClient {

    static let firstOpenFlag = "first_open_sent"

    /// An empty file: the site's last answer was that it is not consent gated (a US or Other site). Written only then,
    /// so a gated site writes nothing, and no file, the same as no answer, reads as gated.
    static let notGatedFlag = "site_not_consent_gated"

    /// What could not run because the install id could not be read, waiting for a call that can.
    private enum Waiting: Sendable {
        case consent(analytics: Bool, marketing: Bool)
        case conversion(Event)
    }

    /// From the app's Info.plist. Nil outside an app, which the server accepts.
    private static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    nonisolated let directory: URL
    nonisolated let log: TraceLog
    private nonisolated let values: ConversionValues
    private nonisolated let sender: any EventSender
    private let gate: ConsentGate
    // ponytail: unbounded, and only ever filled between a reboot and the first unlock, by a background launch. Bound
    // it if an app is found calling Trace in a loop in that window.
    private var waiting: [Waiting] = []
    /// Whether this launch has recorded its first open. In memory only: the flag on disk is written when it is sent.
    private var firstOpenRecorded = false
    private nonisolated let tail = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    // What Apple may hear (the legal adviser's answers, decided by Dom on 8 October 2026). Registering the install,
    // writing the two Apple files and every conversion value update wait for a grant on a consent gated site, as the
    // website tag waits, and on a site that is not gated they happen unless the person refused. A refusal or a
    // withdrawal stops them and removes the files. None of this is stored: the answer is the host app's.

    /// This launch's answer, nil until ``setConsent(analytics:marketing:)``.
    private var consent: Bool?
    /// The site's rule: this launch's answer from the API, else the last one kept, else gated.
    private var gated: Bool
    /// Whether this launch has finished asking the site. Until then only a grant lets Apple hear anything.
    private var siteAsked = false
    /// Whether this launch has registered with Apple, or found it already registered, with permission.
    private var toldApple = false
    /// Value updates made while Apple may not hear them yet, in order, for a grant to apply. In memory only, bounded
    /// like the held events, and thrown away by a refusal.
    private var forApple: [@Sendable () async -> Void] = []

    init(directory: URL = Storage.defaultDirectory, sender: any EventSender, registrar: any ConversionValueRegistrar,
         log: TraceLog) {
        self.directory = directory
        self.log = log
        self.sender = sender
        values = ConversionValues(directory: directory, registrar: registrar, log: log)
        gate = ConsentGate(directory: directory, sender: sender, log: log)
        gated = !Storage.flagIsSet(Self.notGatedFlag, in: directory)
    }

    /// Asks the site whether it is consent gated, records the first open if it has never been recorded, then, behind
    /// whatever the app called meanwhile, registers with Apple if that is allowed.
    nonisolated func launch() {
        enqueue {
            await self.askTheSite()
            await self.run(nil)
        }
    }

    nonisolated func setConsent(analytics: Bool, marketing: Bool) {
        enqueue { await self.run(.consent(analytics: analytics, marketing: marketing)) }
    }

    nonisolated func conversion(_ name: String, value: Double?, metadata: [String: String]) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            log.log("a conversion needs a name, so nothing was sent")
            return
        }
        reportWhatTheServerWouldDrop(metadata)
        // Made here, on the calling thread, so its timestamp is when it happened rather than when the queue reached
        // it. The key is filled in by the consent gate when it is sent, because before a grant there is none.
        let event = Event(type: name.lowercased() == "purchase" ? .purchase : .custom, anonUserKey: "",
                          consentStatus: .unknown, appVersion: Self.appVersion, eventName: name, value: value,
                          metadata: metadata.isEmpty ? nil : metadata)
        let values = values
        enqueue {
            await self.tellApple { await values.conversionRecorded(value: value) }
            await self.run(.conversion(event))
        }
    }

    nonisolated func setConversionValue(fine: Int, coarse: CoarseValue) {
        let values = values
        enqueue { await self.tellApple { await values.set(fine: fine, coarse: coarse) } }
    }

    nonisolated var installId: String? { InstallId.peek(in: directory) }

    /// Waits until everything called so far has run, including what that work queued behind it.
    func idle() async {
        while let last = tail.withLock({ $0 }) {
            await last.value
            if tail.withLock({ $0 }) == last { return }
        }
    }

    // The site's answer is kept only when it is "not gated", so a gated site writes nothing before consent. The
    // decision waits behind the calls made so far: an app passes its stored answer straight after initialise, and a
    // refusal there must come before registering, not undo it a moment later.
    private func askTheSite() async {
        if let answer = await sender.consentGated() {
            gated = answer
            if answer {
                Storage.remove(Self.notGatedFlag, in: directory)
            } else if !Storage.flagIsSet(Self.notGatedFlag, in: directory) {
                Storage.setFlag(Self.notGatedFlag, in: directory, log: log)
            }
        }
        enqueue {
            await self.siteWasAsked()
        }
    }

    private func siteWasAsked() async {
        siteAsked = true
        await tellAppleIfAllowed()
    }

    // Nothing for someone who refused, and nothing kept for later.
    private func tellApple(_ update: @escaping @Sendable () async -> Void) async {
        guard consent != false else { return }
        forApple.append(update)
        if forApple.count > ConsentGate.maxHeld { forApple.removeFirst() }
        await tellAppleIfAllowed()
    }

    private func tellAppleIfAllowed() async {
        guard consent == true || (consent == nil && siteAsked && !gated) else { return }
        if !toldApple {
            toldApple = true
            await values.launched()
        }
        let updates = forApple
        forApple = []
        for update in updates { await update() }
    }

    private func answered(analytics: Bool) async {
        consent = analytics
        if analytics {
            await tellAppleIfAllowed()
        } else {
            forApple = []
            toldApple = false
            values.forget()
        }
    }

    private nonisolated func enqueue(_ work: @escaping @Sendable () async -> Void) {
        tail.withLock { last in
            let before = last
            last = Task {
                await before?.value
                await work()
            }
        }
    }

    // Adds `next` to what is waiting, then runs everything that can run, in order, stopping at an answer that needs
    // the install id while it cannot be read. The first open goes first: it is the oldest thing there is.
    private func run(_ next: Waiting?) async {
        if let next { waiting.append(next) }
        await recordFirstOpenIfNeeded()
        while let first = waiting.first {
            switch first {
            case .consent(let analytics, let marketing):
                guard await gate.setConsent(analytics: analytics, marketing: marketing) else { return stillWaiting() }
                await answered(analytics: analytics)
            case .conversion(let event):
                await gate.record(event)
            }
            waiting.removeFirst()
        }
    }

    private func stillWaiting() {
        log.log("the install id cannot be read yet, as before the first unlock after a reboot, so nothing was sent "
                + "or minted and \(waiting.count) call(s) wait for the next one")
    }

    // Once a launch, and once ever: the gate writes the flag when it sends the first open after a grant. A launch
    // that ends before an answer writes no flag, so the next launch records a first open again. Only the flag's
    // existence is read, which works before the first unlock after a reboot, and no key is needed: the gate stamps
    // it on when it sends.
    private func recordFirstOpenIfNeeded() async {
        guard !firstOpenRecorded, !Storage.flagIsSet(Self.firstOpenFlag, in: directory) else { return }
        firstOpenRecorded = true
        await gate.record(Event(type: .firstOpen, anonUserKey: "", consentStatus: .unknown, appVersion: Self.appVersion))
    }

    // Reported, not changed: what the server keeps is the server's decision.
    private nonisolated func reportWhatTheServerWouldDrop(_ metadata: [String: String]) {
        let dropped = metadata.keys.filter { $0.wholeMatch(of: /[A-Za-z0-9_]{1,64}/) == nil }.sorted()
        if !dropped.isEmpty {
            log.log("the server keeps metadata keys of letters, digits and underscores only, so it will drop: "
                    + dropped.joined(separator: ", "))
        }
        if metadata.count > 50 {
            log.log("the server keeps at most 50 metadata keys and this conversion has \(metadata.count)")
        }
    }
}
