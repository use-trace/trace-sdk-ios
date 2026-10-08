import Foundation

/// Holds events until the host app says what the person answered, then sends them or throws them away.
///
/// The rule it exists for is hold, then send. An event sent before the banner was answered cannot be unsent, and
/// the server deleting it later is not the same thing as never having had it.
///
/// **The consent call goes before the held events, always.** On a consent gated site the server buffers an event it
/// receives without consent and replays it once consent arrives, taking the anonymous key from the consent call. An
/// event that overtakes the consent call makes the server mint a key of its own and record it as though it were this
/// app's install id: a false provenance, not a missing field, and nothing on this side can see it happen.
///
/// `analytics` is the answer that gates events. `marketing` is passed on to the server for the record and never
/// decides whether an event is sent, so marketing alone discards the queue like any other refusal.
///
/// **Nothing is written to the device before an answer.** Decided 6 October 2026, before the first release. The held
/// events live in memory only, the install id is minted and written by the grant, and the first open flag is written
/// when the first open is sent. A refusal writes no identifier, only ``answerReportedFlag`` once the server has
/// counted it. The cost is accepted: an app killed with its banner still
/// on screen loses what was held, and its next launch, finding no first open flag, records a first open again. At
/// most 100 events are held; past that the oldest goes, because the newest conversions are the ones still worth
/// sending.
///
/// Events are recorded with no key, because before a grant there is none, and the gate stamps the install id on
/// each one as it sends it.
///
/// The consent state is not persisted. A new process starts at `unknown` and holds until the host app says what
/// the person answered, which an app has to do on every launch anyway, because the answer is the app's to keep.
///
/// **One operation at a time, in the order called.** An actor can interleave at every `await`, so without that an
/// event recorded while a grant's consent call was in flight would be sent straight away, ahead of the consent call
/// finishing and ahead of the held events. Each call waits for the one before it to finish.
actor ConsentGate {

    static let maxHeld = 100

    /// An empty file: this install's first consent answer has reached Trace, so every later consent call is a repeat
    /// and the share who said yes counts it once. Written only once the server has taken an answer, a grant or a
    /// refusal, never before one, and it holds nothing. 0.2.0 kept this in the conversion value record, which a
    /// refusal now removes.
    static let answerReportedFlag = "answer_reported"

    /// Whether the server has taken this install's first answer: the flag, or a record 0.2.0 wrote. Nil when that
    /// record cannot be read yet, before the first unlock after a reboot.
    static func answerReported(in directory: URL) -> Bool? {
        Storage.flagIsSet(answerReportedFlag, in: directory) ? true : ConversionValues.answerReported(in: directory)
    }

    /// `unknown` until ``setConsent(analytics:marketing:)`` is called.
    private(set) var state: ConsentState = .unknown

    /// The install id, read or minted by the grant. Set whenever ``state`` is `granted`.
    private var key = ""
    /// What is held while the state is `unknown`, oldest first. In memory only, never on disk.
    private var held: [Event] = []

    private let directory: URL
    private let sender: any EventSender
    private let log: TraceLog
    private var latest: Task<Void, Never>?

    init(directory: URL = Storage.defaultDirectory, sender: any EventSender, log: TraceLog = .silent) {
        self.directory = directory
        self.sender = sender
        self.log = log
    }

    /// Sends the event, holds it or drops it, according to ``state``. It never says which: an event held is not
    /// lost, an event dropped was refused, and there is nothing for a caller to do about either.
    func record(_ event: Event) async {
        await inOrder { await self.recordNow(event) }
    }

    /// Records the answer, tells the server, then flushes or discards everything held.
    ///
    /// A grant mints and writes the install id if there is none yet, then sends the consent call, then the held
    /// events oldest first, each stamped with the id and `GRANTED`: the server treats an event's `consent_status` as
    /// authoritative, so one flushed by a grant that still said `UNKNOWN` would be quarantined after the person had
    /// agreed.
    ///
    /// A refusal still sends the consent call, because that is what withdraws an earlier grant, but only when this
    /// install already has an id. It reads the id with `peek`, never `get`: minting one to report a refusal would
    /// create the identifier the person has just declined.
    ///
    /// Nothing is held when this returns, flushed or discarded, and a refusal writes no identifier. A send the server did
    /// not take is not kept: the transport has already retried what was worth retrying.
    ///
    /// **Returns false, having changed nothing, when the install id exists and cannot be read**, which on iOS is the
    /// phone before its first unlock after a reboot. A grant then would flush the held events without the consent
    /// call that must go before them, and a refusal could not withdraw under the id it cannot read. So the state, what
    /// is held and the server are left as they were, and the caller asks again later.
    @discardableResult
    func setConsent(analytics: Bool, marketing: Bool) async -> Bool {
        await inOrder { await self.setConsentNow(analytics: analytics, marketing: marketing) }
    }

    private func inOrder<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        let before = latest
        let current = Task {
            await before?.value
            return await work()
        }
        latest = Task { _ = await current.value }
        return await current.value
    }

    private func recordNow(_ event: Event) async {
        switch state {
        case .unknown:
            hold(event)
        case .granted:
            await send(event)
        case .denied:
            // Nothing is kept for a later change of mind. A person who refuses and then agrees is tracked from the
            // moment they agreed, which is the whole of what consent means.
            log.log("\(event.type.rawValue) dropped, consent was refused")
        }
    }

    private func setConsentNow(analytics: Bool, marketing: Bool) async -> Bool {
        let key: String?
        // Read before the grant can mint an id: a grant is the install's first answer only if it mints the id and no
        // answer has been reported before (a refusal, or a grant the server took).
        let minting = InstallId.read(in: directory) == .absent
        let reported = Self.answerReported(in: directory)
        if analytics {
            key = InstallId.get(in: directory)
            if key == nil {
                log.log("the install id cannot be read or stored yet, so the grant waits and nothing is sent")
                return false
            }
        } else {
            let stored = InstallId.read(in: directory)
            if stored == .unreadable {
                log.log("the install id cannot be read yet, so the refusal waits and nothing is sent or discarded")
                return false
            }
            key = InstallId.peek(in: directory)
        }
        state = analytics ? .granted : .denied
        self.key = key ?? ""
        let flushing = held
        held = []

        if let key {
            let first = analytics && minting && reported == false
            if await sender.sendConsent(key: key, analytics: analytics, marketing: marketing, firstAnswer: first), first {
                Storage.setFlag(Self.answerReportedFlag, in: directory, log: log)
            }
        } else if reported == false {
            // Counted, never identified: the call carries no key, and what remembers it is an empty flag written
            // after the answer, like the website banner's `declined`. Not taken, it is tried again on the next launch.
            log.log("consent refused before this install had an identity, reporting the answer with no identifier")
            if await sender.sendFirstRefusal(marketing: marketing) {
                Storage.setFlag(Self.answerReportedFlag, in: directory, log: log)
            }
        } else {
            log.log("consent refused before this install had an identity, and the answer was reported before")
        }

        if analytics {
            log.log("consent granted, sending \(flushing.count) held event(s)")
            for event in flushing { await send(event) }
        } else {
            log.log("consent refused, discarding \(flushing.count) held event(s)")
        }
        return true
    }

    // Stamped with the key and GRANTED here, because neither was known when the event was recorded. The first open
    // flag is written after the first open has gone to the transport, whether or not the server took it, because
    // there is no retry across launches; a flag written first would suppress an install that was never sent.
    //
    // The exception is a wrong configuration (a wrong address, or an api key the API refused): the first open
    // certainly did not reach Trace, so the flag is not written and the next launch sends it again, which reports the
    // install once the app ships with the configuration fixed.
    private func send(_ event: Event) async {
        var granted = event
        granted.anonUserKey = key
        granted.consentStatus = .granted
        let delivery = await sender.send(granted)
        guard event.type == .firstOpen else { return }
        if delivery == .wrongConfiguration {
            log.log("the first open did not reach the Trace API, so the next launch sends it again")
        } else {
            Storage.setFlag(TraceClient.firstOpenFlag, in: directory, log: log)
        }
    }

    private func hold(_ event: Event) {
        held.append(event)
        if held.count > Self.maxHeld {
            let dropped = held.count - Self.maxHeld
            held.removeFirst(dropped)
            log.log("the held queue is full at \(Self.maxHeld), dropped the \(dropped) oldest held event(s)")
        }
        log.log("\(event.type.rawValue) held in memory until the consent state is known, \(held.count) now held")
    }
}
