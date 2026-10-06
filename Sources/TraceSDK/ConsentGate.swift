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
/// **The queue is on disk, not in memory**, so an app killed with its banner on screen does not lose its first
/// open. It is one file beside the install id, excluded from backup for the same reason: it carries that id, and a
/// queue restored onto a later install would send events for a visitor who no longer exists. At most 100 events
/// are held; past that the oldest goes, because the newest conversions are the ones still worth sending.
///
/// The consent state is not persisted. A new process starts at `unknown` and holds until the host app says what
/// the person answered, which an app has to do on every launch anyway, because the answer is the app's to keep.
///
/// **One operation at a time, in the order called.** An actor can interleave at every `await`, so without that an
/// event recorded while a grant's consent call was in flight would be sent straight away, ahead of the consent call
/// finishing and ahead of the held events. Each call waits for the one before it to finish.
actor ConsentGate {

    static let fileName = "held_events"
    static let maxHeld = 100

    /// `unknown` until ``setConsent(analytics:marketing:)`` is called.
    private(set) var state: ConsentState = .unknown

    private let directory: URL
    private let queueFile: URL
    private let sender: any EventSender
    private let log: TraceLog
    private var latest: Task<Void, Never>?

    init(directory: URL = Storage.defaultDirectory, sender: any EventSender, log: TraceLog = .silent) {
        self.directory = directory
        queueFile = directory.appending(path: Self.fileName)
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
    /// The consent call first, then the held events oldest first, each stamped `GRANTED`: the server treats an
    /// event's `consent_status` as authoritative, so one flushed by a grant that still said `UNKNOWN` would be
    /// quarantined after the person had agreed.
    ///
    /// A refusal still sends the consent call, because that is what withdraws an earlier grant, but only when this
    /// install already has an id. It reads the id with `peek`, never `get`: minting one to report a refusal would
    /// create the identifier the person has just declined.
    ///
    /// The queue file is gone from disk when this returns, flushed or discarded. A send the server did not take is
    /// not kept: the transport has tried three times, and a file that outlives the answer is one some later launch
    /// sends again.
    func setConsent(analytics: Bool, marketing: Bool) async {
        await inOrder { await self.setConsentNow(analytics: analytics, marketing: marketing) }
    }

    private func inOrder(_ work: @escaping @Sendable () async -> Void) async {
        let before = latest
        let current = Task {
            await before?.value
            await work()
        }
        latest = current
        await current.value
    }

    private func recordNow(_ event: Event) async {
        switch state {
        case .unknown:
            hold(event)
        case .granted:
            var granted = event
            granted.consentStatus = .granted
            _ = await sender.send(granted)
        case .denied:
            // Nothing is kept for a later change of mind. A person who refuses and then agrees is tracked from the
            // moment they agreed, which is the whole of what consent means.
            log.log("\(event.type.rawValue) dropped, consent was refused")
        }
    }

    private func setConsentNow(analytics: Bool, marketing: Bool) async {
        state = analytics ? .granted : .denied
        let held = readHeld()

        if let key = analytics ? InstallId.get(in: directory) : InstallId.peek(in: directory) {
            _ = await sender.sendConsent(key: key, analytics: analytics, marketing: marketing)
        } else {
            log.log("consent refused before this install had an identity, so there is nothing to withdraw")
        }

        if analytics {
            log.log("consent granted, sending \(held.count) held event(s)")
            for event in held {
                var granted = event
                granted.consentStatus = .granted
                _ = await sender.send(granted)
            }
        } else {
            log.log("consent refused, discarding \(held.count) held event(s)")
        }
        clearHeld()
    }

    private func hold(_ event: Event) {
        var held = readHeld()
        held.append(event)
        if held.count > Self.maxHeld {
            let dropped = held.count - Self.maxHeld
            held.removeFirst(dropped)
            log.log("the held queue is full at \(Self.maxHeld), dropped the \(dropped) oldest held event(s)")
        }
        write(held)
        log.log("\(event.type.rawValue) held until the consent state is known, \(held.count) now held")
    }

    // One event per line, in the form it will be sent. The whole file is rewritten, which at a hundred lines is
    // cheap, and a write is atomic, so a process killed mid write leaves the previous queue rather than half of one.
    private func write(_ held: [Event]) {
        let lines = held.compactMap { $0.json() }
        do {
            try Storage.write(Data(lines.joined(separator: Data("\n".utf8))), to: queueFile)
        } catch {
            log.log("could not write the held queue, \(held.count) event(s) may be lost")
        }
    }

    // A line that is not an event, from an older crash or a newer SDK, is dropped rather than failing the queue.
    private func readHeld() -> [Event] {
        guard let data = try? Data(contentsOf: queueFile) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { Event(json: Data($0)) }
    }

    // Gone, not emptied. If it cannot be deleted it is emptied, so at least nothing in it is sent again.
    private func clearHeld() {
        guard FileManager.default.fileExists(atPath: queueFile.path) else { return }
        do {
            try FileManager.default.removeItem(at: queueFile)
        } catch {
            log.log("could not delete the held queue, emptying it instead")
            try? Storage.write(Data(), to: queueFile)
        }
    }
}
