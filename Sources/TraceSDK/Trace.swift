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
/// install with Apple's conversion value API on the first launch, without which Apple sends no postback at all.
///
/// **No advertising identifier, no tracking prompt, no hashed email.** It does not import `AdSupport` or
/// `AppTrackingTransparency`, and there is no way to pass it an email, a hash of one or a customer id.
///
/// **No method throws into the host app, and no method does network work on the calling thread.** Every call
/// returns at once; the work runs afterwards on the SDK's own tasks, one at a time, in the order the calls were
/// made, so a conversion can never overtake the consent call that has to go before it. A call before
/// ``initialise(_:)`` does nothing and says so in the log.
///
/// **Before the first unlock after a reboot it waits.** An app launched in the background then, by a push or a
/// background refresh, finds the install id's file and cannot read it, because iOS has not decrypted it yet. The SDK
/// then sends nothing and mints nothing, because a new id would make one install two, and the calls made meanwhile
/// run, in order, on the first call after the phone has been unlocked. Nothing is kept on disk for them, so if the
/// app is killed first they are lost.
public enum Trace {

    private static let client = OSAllocatedUnfairLock<TraceClient?>(initialState: nil)

    /// Starts the SDK, registers the install with Apple, and records the first open. Call it once, as early in the
    /// launch as the app can, before ``setConsent(analytics:marketing:)``. A second call does nothing.
    ///
    /// The first open is recorded once, ever, and held with everything else until ``setConsent(analytics:marketing:)``
    /// says what the person answered. An app that never calls it sends nothing, which is correct rather than a bug.
    ///
    /// Registering with Apple does not wait for consent: it sends nothing to Trace and no identity anywhere. See
    /// ``setConversionValue(fine:coarse:)``.
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
    /// A grant sends the consent record, then everything held, oldest first. A refusal sends the consent record,
    /// which withdraws an earlier grant, and throws away everything held. **Call it on every launch**, from the
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
    /// Held while consent is unknown, dropped if it was refused, sent otherwise. The first conversion also raises
    /// Apple's coarse conversion value to `medium`, unless the app has set its own value.
    public static func conversion(_ name: String, value: Double?, metadata: [String: String]) {
        current("conversion")?.conversion(name, value: value, metadata: metadata)
    }

    /// Sets Apple's conversion value, for an app with its own schema. From then on the SDK leaves the value alone.
    ///
    /// `fine` is 0 to 63; anything else is refused with a log line rather than passed to StoreKit to throw. It goes
    /// to SKAdNetwork on iOS 16.1 and later and to AdAttributionKit on iOS 17.4 and later.
    ///
    /// **It does not need Trace consent.** It sends nothing to Trace and no identity anywhere: it updates a value held
    /// by Apple's own privacy preserving attribution system on the device, which Apple reports at campaign level, if
    /// at all, on its own terms. A StoreKit error is logged and never reaches the app.
    public static func setConversionValue(fine: Int, coarse: CoarseValue) {
        current("setConversionValue")?.setConversionValue(fine: fine, coarse: coarse)
    }

    /// The identifier Trace holds for this install, or nil when there is not one yet.
    ///
    /// **Public because a person's rights depend on it.** Someone asking what Trace holds about them, or asking for
    /// it to be deleted, has to find their identifier first, and an app has no browser settings to look in, so the
    /// app shows it on its own privacy screen. Nil before ``initialise(_:)``, nil until something has been recorded,
    /// and nil before the first unlock after a reboot. Reading it creates nothing and sends nothing.
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
    private let gate: ConsentGate
    // ponytail: unbounded, and only ever filled between a reboot and the first unlock, by a background launch. Bound
    // it if an app is found calling Trace in a loop in that window.
    private var waiting: [Waiting] = []
    private nonisolated let tail = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    init(directory: URL = Storage.defaultDirectory, sender: any EventSender, registrar: any ConversionValueRegistrar,
         log: TraceLog) {
        self.directory = directory
        self.log = log
        values = ConversionValues(directory: directory, registrar: registrar, log: log)
        gate = ConsentGate(directory: directory, sender: sender, log: log)
    }

    /// Registers the install with Apple, then records the first open if it has never been recorded.
    nonisolated func launch() {
        enqueue {
            await self.values.registerInstall()
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
        // it. The key is filled in when it runs, because it may not be readable yet.
        let event = Event(type: name.lowercased() == "purchase" ? .purchase : .custom, anonUserKey: "",
                          consentStatus: .unknown, appVersion: Self.appVersion, eventName: name, value: value,
                          metadata: metadata.isEmpty ? nil : metadata)
        enqueue {
            await self.values.conversionRecorded()
            await self.run(.conversion(event))
        }
    }

    nonisolated func setConversionValue(fine: Int, coarse: CoarseValue) {
        enqueue { await self.values.set(fine: fine, coarse: coarse) }
    }

    nonisolated var installId: String? { InstallId.peek(in: directory) }

    /// Waits until everything called so far has run.
    func idle() async {
        await tail.withLock { $0 }?.value
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

    // Adds `next` to what is waiting, then runs everything that can run, in order, stopping at the first thing that
    // needs the install id while it cannot be read. The first open goes first: it is the oldest thing there is.
    private func run(_ next: Waiting?) async {
        if let next { waiting.append(next) }
        guard await recordFirstOpenIfNeeded() else { return stillWaiting() }
        while let first = waiting.first {
            switch first {
            case .consent(let analytics, let marketing):
                guard await gate.setConsent(analytics: analytics, marketing: marketing) else { return stillWaiting() }
            case .conversion(var event):
                guard let key = InstallId.get(in: directory) else { return stillWaiting() }
                event.anonUserKey = key
                await gate.record(event)
            }
            waiting.removeFirst()
        }
    }

    private func stillWaiting() {
        log.log("the install id cannot be read yet, as before the first unlock after a reboot, so nothing was sent "
                + "or minted and \(waiting.count) call(s) wait for the next one")
    }

    // Once, ever. The flag is written after the gate has taken the event, not before: the gate has sent it or
    // written it to disk, so it is the gate's to deliver, and a flag written first would suppress an install the
    // gate never received. A process killed in between records the install twice, which over counts one install
    // and is the better of the two failures.
    private func recordFirstOpenIfNeeded() async -> Bool {
        guard !Storage.flagIsSet(Self.firstOpenFlag, in: directory) else { return true }
        guard let key = InstallId.get(in: directory) else { return false }
        await gate.record(Event(type: .firstOpen, anonUserKey: key, consentStatus: .unknown, appVersion: Self.appVersion))
        Storage.setFlag(Self.firstOpenFlag, in: directory, log: log)
        return true
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
