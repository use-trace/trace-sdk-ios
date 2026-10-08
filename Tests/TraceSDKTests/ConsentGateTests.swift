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
        var firstAnswers: [Bool] = []
    }

    private let recorded = OSAllocatedUnfairLock(initialState: Recorded())
    private let consentDelay: Duration
    private let refusalTaken: Bool
    private let gated: Bool?

    /// `consentDelay` holds the consent call open, so a test can do something else while it is in flight.
    /// `refusalTaken` false is a server that did not take the first refusal. `gated` is what the site's config says,
    /// nil for no answer (offline, or an older API).
    init(consentDelay: Duration = .zero, refusalTaken: Bool = true, gated: Bool? = nil) {
        self.consentDelay = consentDelay
        self.refusalTaken = refusalTaken
        self.gated = gated
    }

    var calls: [String] { recorded.withLock { $0.calls } }
    var events: [Event] { recorded.withLock { $0.events } }
    var consentKeys: [String] { recorded.withLock { $0.consentKeys } }
    /// `first_answer` on each consent call, the first refusal included, in order.
    var firstAnswers: [Bool] { recorded.withLock { $0.firstAnswers } }

    func send(_ event: Event) async -> Delivery {
        recorded.withLock {
            $0.calls.append("event \(event.eventName ?? event.type.rawValue)")
            $0.events.append(event)
        }
        return .delivered
    }

    func sendConsent(key: String, analytics: Bool, marketing: Bool, firstAnswer: Bool) async -> Bool {
        recorded.withLock {
            $0.calls.append("consent analytics=\(analytics) marketing=\(marketing)")
            $0.consentKeys.append(key)
            $0.firstAnswers.append(firstAnswer)
        }
        try? await Task.sleep(for: consentDelay)
        return true
    }

    // Answers at once. Nothing in the SDK's ordering depends on how long the site takes to answer.
    func consentGated() async -> Bool? {
        gated
    }

    func sendFirstRefusal(marketing: Bool) async -> Bool {
        recorded.withLock {
            $0.calls.append("first refusal marketing=\(marketing)")
            $0.firstAnswers.append(true)
        }
        return refusalTaken
    }
}

/// The consent gate over a temporary directory, sending through a ``RecordingSender``. Every log line goes through a
/// ``LogCapture``: the gate stamps install ids on what it sends, which makes it the easiest place in the SDK to leak
/// one into a log.
struct ConsentGateTests {

    let directory = temporaryDirectory()
    let capture = LogCapture()

    /// Every file in the directory. The held queue is never one of them: it lives in memory only.
    private var written: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted() }

    private func gate(_ sender: RecordingSender) -> ConsentGate {
        ConsentGate(directory: directory, sender: sender, log: capture.log)
    }

    // Recorded with no key, as the SDK records it: there is no install id before a grant, and the gate stamps it on
    // as it sends.
    private func event(_ name: String, _ type: EventType = .custom) -> Event {
        Event(type: type, anonUserKey: "", consentStatus: .unknown, eventName: name)
    }

    @Test func anEventRecordedWhileConsentIsUnknownIsNotSent() async {
        let sender = RecordingSender()
        let gate = gate(sender)

        await gate.record(event("first open", .firstOpen))

        #expect(await gate.state == .unknown)
        #expect(sender.calls.isEmpty)
        #expect(written.isEmpty, "a held event is held in memory, never on disk")
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

    @Test func heldEventsAreSentUnderTheInstallIdTheGrantWrote() async throws {
        let sender = RecordingSender()
        let gate = gate(sender)
        await gate.record(event("first open", .firstOpen))
        await gate.record(event("signup"))

        await gate.setConsent(analytics: true, marketing: false)

        let id = try #require(InstallId.peek(in: directory))
        #expect(sender.events.map(\.anonUserKey) == [id, id])
        // The empty flag remembers that the first answer was reported.
        #expect(written == [TraceClient.firstOpenFlag, InstallId.fileName, ConsentGate.answerReportedFlag].sorted())
    }

    @Test(arguments: [false, true])
    func aDenialDiscardsTheHeldEventsAndSendsNone(marketing: Bool) async {
        let sender = RecordingSender()
        let gate = gate(sender)
        _ = InstallId.get(in: directory) // an earlier launch's grant, so there is a grant to withdraw
        await gate.record(event("first open", .firstOpen))
        await gate.record(event("signup"))

        await gate.setConsent(analytics: false, marketing: marketing)

        // The consent call still goes, because it is what withdraws an earlier grant. No event goes.
        #expect(sender.calls == ["consent analytics=false marketing=\(marketing)"])
        #expect(sender.events.isEmpty)
    }

    // Reporting a refusal must not create the identifier the person has just declined. It is reported once, with no
    // identifier, so the server can count it (the share who said yes, APP_MODELLED_INSTALLS.md decision 3).
    @Test func aRefusalBeforeThereIsAnyIdMintsNoneAndIsReportedOnceWithNoIdentifier() async {
        let sender = RecordingSender()

        await gate(sender).setConsent(analytics: false, marketing: false)
        await gate(sender).setConsent(analytics: false, marketing: false)

        #expect(sender.calls == ["first refusal marketing=false"], "a later launch's refusal is a repeat, not sent")
        #expect(sender.consentKeys.isEmpty)
        #expect(InstallId.peek(in: directory) == nil)
        #expect(written == [ConsentGate.answerReportedFlag], "only the empty answer flag may remember it")
    }

    @Test func aFirstRefusalTheServerDidNotTakeIsReportedAgainOnTheNextLaunch() async {
        await gate(RecordingSender(refusalTaken: false)).setConsent(analytics: false, marketing: false)

        let next = RecordingSender()
        await gate(next).setConsent(analytics: false, marketing: false)

        #expect(next.calls == ["first refusal marketing=false"])
    }

    // Each install's answer is counted once: the first consent call says so, and every later one says it is not.
    @Test func theFirstGrantIsTheFirstAnswerAndEveryLaterCallIsNot() async {
        let first = RecordingSender()
        let gate = gate(first)
        await gate.setConsent(analytics: true, marketing: false)
        await gate.setConsent(analytics: false, marketing: false)
        let later = RecordingSender()
        await self.gate(later).setConsent(analytics: true, marketing: false)

        #expect(first.firstAnswers == [true, false], "a withdrawal is never a first answer")
        #expect(later.firstAnswers == [false])
    }

    @Test func aGrantAfterAReportedRefusalIsNotAFirstAnswer() async {
        await gate(RecordingSender()).setConsent(analytics: false, marketing: false)

        let sender = RecordingSender()
        await gate(sender).setConsent(analytics: true, marketing: false)

        #expect(sender.firstAnswers == [false])
    }

    // 0.2.0 kept "the first answer reached Trace" in the conversion value record. An install that answered under it
    // is not counted a second time by 0.3.0, which keeps it in an empty flag instead.
    @Test func anAnswerA020RecordSaysWasReportedIsNotReportedAgain() async throws {
        try Storage.write(Data(#"{"schema":1,"firstLaunch":0,"window":0,"converted":false,"revenue":0,"setByApp":false,"answerReported":true}"#.utf8),
                          to: directory.appending(path: ConversionValues.stateFile))
        let sender = RecordingSender()

        await gate(sender).setConsent(analytics: false, marketing: false)

        #expect(sender.calls.isEmpty)
    }

    // An install that granted under 0.1.0 has an id and no record of having answered. Its grant is a repeat.
    @Test func aGrantFromAnInstallThatAlreadyHadAnIdIsNotAFirstAnswer() async throws {
        _ = try #require(InstallId.get(in: directory))
        let sender = RecordingSender()

        await gate(sender).setConsent(analytics: true, marketing: false)

        #expect(sender.firstAnswers == [false])
    }

    @Test func anEventRecordedAfterAGrantIsSentStraightAwayAsGranted() async {
        let sender = RecordingSender()
        let gate = gate(sender)
        await gate.setConsent(analytics: true, marketing: false)

        await gate.record(event("afterwards"))

        #expect(sender.calls == ["consent analytics=true marketing=false", "event afterwards"])
        #expect(sender.events.map(\.consentStatus) == [.granted])
        #expect(sender.events.map(\.anonUserKey) == [InstallId.peek(in: directory)])
    }

    @Test func anEventRecordedAfterADenialIsDroppedAndNothingIsSent() async {
        let sender = RecordingSender()
        let gate = gate(sender)
        await gate.setConsent(analytics: false, marketing: false)

        await gate.record(event("afterwards"))

        #expect(sender.events.isEmpty)
        #expect(written == [ConsentGate.answerReportedFlag], "only the empty flag, remembering the answer was reported")
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
    // Decided 6 October 2026: nothing is stored before consent, and losing what was held to a kill is the cost.
    @Test func theQueueIsInMemoryOnlySoItDoesNotSurviveARestart() async {
        await gate(RecordingSender()).record(event("first open", .firstOpen))
        await gate(RecordingSender()).record(event("signup"))
        #expect(written.isEmpty)

        let sender = RecordingSender()
        await gate(sender).setConsent(analytics: true, marketing: false)

        #expect(sender.calls == ["consent analytics=true marketing=false"])
    }

    @Test func theQueueIsBoundedAtAHundredAndTheOldestGoesFirst() async {
        let sender = RecordingSender()
        let gate = gate(sender)
        for n in 0...100 { await gate.record(event("event \(n)")) }

        await gate.setConsent(analytics: true, marketing: false)

        #expect(sender.events.map(\.eventName) == (1...100).map { "event \($0)" })
        #expect(capture.lines.contains { $0.contains("dropped") }, "dropping an event should say so")
    }

    // Before the first unlock after a reboot the id file exists and cannot be read. A grant then would flush the
    // held events with no consent call before them, and a refusal could not withdraw under the id. So neither
    // changes anything: no call, the queue kept, the state still unknown, and false so the caller asks again.
    @Test(arguments: [true, false])
    func anAnswerWhileTheIdCannotBeReadChangesNothing(analytics: Bool) async throws {
        let sender = RecordingSender()
        let gate = gate(sender)
        _ = try #require(InstallId.get(in: directory)) // written by a grant on an earlier launch
        await gate.record(event("first open", .firstOpen))
        let file = directory.appending(path: InstallId.fileName)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

        #expect(await gate.setConsent(analytics: analytics, marketing: false) == false)

        #expect(sender.calls.isEmpty)
        #expect(await gate.state == .unknown)

        // Unlocked: the queue was kept, so a grant now sends what was held.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        await gate.setConsent(analytics: true, marketing: false)
        #expect(sender.calls == ["consent analytics=true marketing=false", "event first open"])
    }
}
