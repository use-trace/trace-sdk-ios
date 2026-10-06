import Foundation
import os
import Testing
@testable import TraceSDK

/// What the gate asked to send, in order. Each call is a short line, so an assertion is a list that reads like the
/// sequence it checks: order is what most of these tests are about.
final class RecordingSender: EventSender {

    private struct Recorded: Sendable {
        var calls: [String] = []
        var events: [Event] = []
        var consentKeys: [String] = []
    }

    private let recorded = OSAllocatedUnfairLock(initialState: Recorded())
    private let consentDelay: Duration

    /// `consentDelay` holds the consent call open, so a test can do something else while it is in flight.
    init(consentDelay: Duration = .zero) {
        self.consentDelay = consentDelay
    }

    var calls: [String] { recorded.withLock { $0.calls } }
    var events: [Event] { recorded.withLock { $0.events } }
    var consentKeys: [String] { recorded.withLock { $0.consentKeys } }

    func send(_ event: Event) async -> Bool {
        recorded.withLock {
            $0.calls.append("event \(event.eventName ?? event.type.rawValue)")
            $0.events.append(event)
        }
        return true
    }

    func sendConsent(key: String, analytics: Bool, marketing: Bool) async -> Bool {
        recorded.withLock {
            $0.calls.append("consent analytics=\(analytics) marketing=\(marketing)")
            $0.consentKeys.append(key)
        }
        try? await Task.sleep(for: consentDelay)
        return true
    }
}

/// The consent gate over a real file in a temporary directory, sending through a ``RecordingSender``. Every log line
/// goes through a ``LogCapture``: the held queue is full of install ids, which makes the gate the easiest place in
/// the SDK to leak one into a log.
struct ConsentGateTests {

    let directory = temporaryDirectory()
    let capture = LogCapture()

    private var queueFile: URL { directory.appending(path: "held_events") }
    private var queueExists: Bool { FileManager.default.fileExists(atPath: queueFile.path) }

    private func gate(_ sender: RecordingSender) -> ConsentGate {
        ConsentGate(directory: directory, sender: sender, log: capture.log)
    }

    private func event(_ name: String, _ type: EventType = .custom) -> Event {
        Event(type: type, anonUserKey: InstallId.get(in: directory)!, consentStatus: .unknown, eventName: name)
    }

    @Test func anEventRecordedWhileConsentIsUnknownIsNotSent() async {
        let sender = RecordingSender()
        let gate = gate(sender)

        await gate.record(event("first open", .firstOpen))

        #expect(await gate.state == .unknown)
        #expect(sender.calls.isEmpty)
        #expect(queueExists, "a held event is held on disk")
    }

    // The server takes the key for a replayed event from the consent call. An event that overtakes it makes the
    // server mint a key of its own and record it as this install's: a false provenance nothing here can see.
    @Test func aGrantSendsTheConsentCallBeforeTheHeldEventsOldestFirst() async {
        let sender = RecordingSender()
        let gate = gate(sender)
        await gate.record(event("first open", .firstOpen))
        await gate.record(event("signup"))

        await gate.setConsent(analytics: true, marketing: false)

        #expect(sender.calls == [
            "consent analytics=true marketing=false",
            "event first open",
            "event signup",
        ])
    }

    @Test func theConsentCallCarriesTheInstallId() async {
        let sender = RecordingSender()
        let gate = gate(sender)
        await gate.record(event("first open", .firstOpen))

        await gate.setConsent(analytics: true, marketing: true)

        #expect(sender.consentKeys == [InstallId.peek(in: directory)].compactMap { $0 })
        #expect(sender.consentKeys.count == 1)
    }

    // The server treats consent_status as authoritative, so a flushed event still saying UNKNOWN would be
    // quarantined after the person had agreed, which looks exactly like never sending it.
    @Test func flushedEventsAreStampedGrantedNotTheUnknownTheyWereRecordedWith() async {
        let sender = RecordingSender()
        let gate = gate(sender)
        await gate.record(event("first open", .firstOpen))
        await gate.record(event("signup"))

        await gate.setConsent(analytics: true, marketing: false)

        #expect(sender.events.count == 2)
        #expect(sender.events.allSatisfy { $0.consentStatus == .granted })
    }

    @Test(arguments: [false, true])
    func aDenialDiscardsTheHeldEventsAndSendsNone(marketing: Bool) async {
        let sender = RecordingSender()
        let gate = gate(sender)
        await gate.record(event("first open", .firstOpen))
        await gate.record(event("signup"))

        await gate.setConsent(analytics: false, marketing: marketing)

        // The consent call still goes, because it is what withdraws an earlier grant. No event goes.
        #expect(sender.calls == ["consent analytics=false marketing=\(marketing)"])
        #expect(sender.events.isEmpty)
        #expect(!queueExists)
    }

    // Reporting a refusal must not create the identifier the person has just declined.
    @Test func aRefusalBeforeThereIsAnyIdMintsNoneToReportIt() async {
        let sender = RecordingSender()

        await gate(sender).setConsent(analytics: false, marketing: false)

        #expect(sender.calls.isEmpty)
        #expect(InstallId.peek(in: directory) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: InstallId.fileName).path))
    }

    @Test func anEventRecordedAfterAGrantIsSentStraightAwayAsGranted() async {
        let sender = RecordingSender()
        let gate = gate(sender)
        await gate.setConsent(analytics: true, marketing: false)

        await gate.record(event("afterwards"))

        #expect(sender.calls == ["consent analytics=true marketing=false", "event afterwards"])
        #expect(sender.events.map(\.consentStatus) == [.granted])
        #expect(!queueExists)
    }

    @Test func anEventRecordedAfterADenialIsDroppedAndNothingIsSent() async {
        let sender = RecordingSender()
        let gate = gate(sender)
        await gate.setConsent(analytics: false, marketing: false)

        await gate.record(event("afterwards"))

        #expect(sender.events.isEmpty)
        #expect(!queueExists)
    }

    // An actor can interleave at every await. An event recorded while the grant's consent call is still in flight
    // must not overtake it, nor the held events behind it.
    @Test func anEventRecordedDuringAGrantWaitsForTheConsentCallAndTheHeldEvents() async throws {
        let sender = RecordingSender(consentDelay: .milliseconds(300))
        let gate = gate(sender)
        await gate.record(event("held"))

        async let grant = gate.setConsent(analytics: true, marketing: false)
        try await Task.sleep(for: .milliseconds(100))
        await gate.record(event("during"))
        #expect(await grant)

        #expect(sender.calls == ["consent analytics=true marketing=false", "event held", "event during"])
    }

    // A new gate over the same directory stands in for the app being killed with its banner still on screen.
    @Test func theQueueSurvivesARestart() async {
        await gate(RecordingSender()).record(event("first open", .firstOpen))
        await gate(RecordingSender()).record(event("signup"))

        let sender = RecordingSender()
        await gate(sender).setConsent(analytics: true, marketing: false)

        #expect(sender.calls == ["consent analytics=true marketing=false", "event first open", "event signup"])
    }

    @Test func theQueueIsBoundedAtAHundredAndTheOldestGoesFirst() async {
        let sender = RecordingSender()
        let gate = gate(sender)
        for n in 0...100 { await gate.record(event("event \(n)")) }

        await gate.setConsent(analytics: true, marketing: false)

        #expect(sender.events.map(\.eventName) == (1...100).map { "event \($0)" })
        #expect(capture.lines.contains { $0.contains("dropped") }, "dropping an event should say so")
    }

    // Gone, not emptied: a flush that leaves its events on disk sends them again on the next launch.
    @Test func aFlushLeavesNoQueueFileOnDisk() async {
        let gate = gate(RecordingSender())
        await gate.record(event("first open", .firstOpen))
        #expect(queueExists)

        await gate.setConsent(analytics: true, marketing: false)

        #expect(!queueExists)
    }

    // A denial that leaves the events in a file has not discarded them.
    @Test func aDiscardLeavesNoQueueFileOnDisk() async {
        let gate = gate(RecordingSender())
        await gate.record(event("first open", .firstOpen))
        #expect(queueExists)

        await gate.setConsent(analytics: false, marketing: false)

        #expect(!queueExists)
    }

    // The queue carries the install id, so a backup restored onto a later install would send events for a visitor
    // who no longer exists.
    @Test func theQueueFileIsExcludedFromBackup() async throws {
        let gate = gate(RecordingSender())
        await gate.record(event("first open", .firstOpen))
        await gate.record(event("signup"))

        #expect(try isExcludedFromBackup(queueFile) == true)
    }

    // Before the first unlock after a reboot the id file exists and cannot be read. A grant then would flush the
    // held events with no consent call before them, and a refusal could not withdraw under the id. So neither
    // changes anything: no call, the queue kept, the state still unknown, and false so the caller asks again.
    @Test(arguments: [true, false])
    func anAnswerWhileTheIdCannotBeReadChangesNothing(analytics: Bool) async throws {
        let sender = RecordingSender()
        let gate = gate(sender)
        await gate.record(event("first open", .firstOpen))
        let file = directory.appending(path: InstallId.fileName)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

        #expect(await gate.setConsent(analytics: analytics, marketing: false) == false)

        #expect(sender.calls.isEmpty)
        #expect(queueExists)
        #expect(await gate.state == .unknown)
    }
}
