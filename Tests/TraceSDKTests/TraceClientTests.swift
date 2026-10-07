import Foundation
import Testing
@testable import TraceSDK

/// What ``Trace`` does, through ``TraceClient``, the instance behind it, so these can run in parallel. A new client
/// over the same directory stands in for a new launch of the app.
struct TraceClientTests {

    let directory = temporaryDirectory()
    let capture = LogCapture()

    private func client(_ sender: RecordingSender, _ registrar: FakeRegistrar = FakeRegistrar()) -> TraceClient {
        TraceClient(directory: directory, sender: sender, registrar: registrar, log: capture.log)
    }

    /// A client launched, with whatever the test then does, run to the end.
    private func launch(_ sender: RecordingSender, _ registrar: FakeRegistrar = FakeRegistrar(),
                        then work: (TraceClient) -> Void = { _ in }) async {
        let client = client(sender, registrar)
        client.launch()
        work(client)
        await client.idle()
    }

    @Test func theFirstOpenIsSentOnceEverAcrossLaunches() async {
        let first = RecordingSender()
        await launch(first) { $0.setConsent(analytics: true, marketing: false) }
        let second = RecordingSender()
        await launch(second) { $0.setConsent(analytics: true, marketing: false) }

        #expect(first.calls == ["consent analytics=true marketing=false", "event FIRST_OPEN"])
        #expect(second.calls == ["consent analytics=true marketing=false"])
    }

    /// A launch that sends through the real transport to `server`, granting consent.
    private func launchGranted(through server: StubServer) async {
        let transport = Transport(apiKey: "tk_placeholder", apiURL: server.url.absoluteString, session: server.session,
                                  log: capture.log, backoff: .zero)
        let client = TraceClient(directory: directory, sender: transport, registrar: FakeRegistrar(), log: capture.log)
        client.launch()
        client.setConsent(analytics: true, marketing: false)
        await client.idle()
    }

    private func firstOpens(_ server: StubServer) -> Int {
        server.requests.filter { $0.path == "/v1/event" && $0.json["event_type"] as? String == "FIRST_OPEN" }.count
    }

    // An app shipped with a wrong address (the dashboard answers a POST with a web page and a 200) reports its
    // installs once the address is fixed, instead of having marked each one sent. Nothing new is written for it: the
    // grant writes the install id as it always has, and the first open flag waits.
    @Test func aFirstOpenThatReachedAWrongAddressIsSentAgainOnceTheAddressIsFixed() async throws {
        let wrong = StubServer { _, _ in .body(200, "<!DOCTYPE html><html><body>Trace</body></html>") }
        await launchGranted(through: wrong)
        #expect(firstOpens(wrong) == 1)
        #expect(try written() == ([InstallId.fileName] + appleFlags).sorted(),
                "a first open that never reached Trace must not be marked sent, and nothing else is written for it")

        let fixed = StubServer()
        await launchGranted(through: fixed)
        #expect(firstOpens(fixed) == 1)

        let later = StubServer()
        await launchGranted(through: later)
        #expect(firstOpens(later) == 0, "once delivered, the first open is not sent again")
    }

    // A wrong or revoked api key is the same: the first open never reached Trace, so a later launch sends it again.
    @Test(arguments: [401, 403])
    func aFirstOpenRefusedForItsKeyIsSentAgainOnceTheKeyIsFixed(status: Int) async throws {
        let refusing = StubServer { _, _ in .status(status) }
        await launchGranted(through: refusing)
        #expect(firstOpens(refusing) == 1)
        #expect(try written() == ([InstallId.fileName] + appleFlags).sorted())

        let fixed = StubServer()
        await launchGranted(through: fixed)
        #expect(firstOpens(fixed) == 1)
    }

    // The rule the cases above are the exception to: a first open the transport gave up on for any other reason is
    // still marked sent, because the server may have taken it and there is no retry across launches.
    @Test func aFirstOpenThatFailedForAnyOtherReasonIsNotSentAgain() async {
        let broken = StubServer { _, _ in .status(500) }
        await launchGranted(through: broken)
        #expect(firstOpens(broken) == Transport.attempts)

        let fixed = StubServer()
        await launchGranted(through: fixed)
        #expect(firstOpens(fixed) == 0)
    }

    @Test func theFirstOpenFlagIsExcludedFromBackup() async throws {
        await launch(RecordingSender()) { $0.setConsent(analytics: true, marketing: false) }

        #expect(try isExcludedFromBackup(directory.appending(path: TraceClient.firstOpenFlag)) == true)
    }

    // The trap: before the first unlock after a reboot the id file is there and cannot be read. Nothing may be
    // minted and nothing sent, and the calls made meanwhile run on the first call after the file can be read.
    @Test func whileTheIdFileCannotBeReadNothingIsMintedNothingSentAndItAllRunsLater() async throws {
        let id = try #require(InstallId.get(in: directory))
        let file = directory.appending(path: InstallId.fileName)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let sender = RecordingSender()
        let client = client(sender)

        client.launch()
        client.conversion("signup", value: nil, metadata: [:])
        client.setConsent(analytics: true, marketing: false)
        await client.idle()

        #expect(sender.calls.isEmpty, "nothing may be sent while the install id cannot be read")
        #expect(try written() == [ConversionValues.registeredFlag, ConversionValues.stateFile, InstallId.fileName].sorted(),
                "no new id, no first open flag and no held queue may be written; the Apple files do not wait")

        // The phone is unlocked. The next call runs what waited, in the order it was called, under the first id.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try String(contentsOf: file, encoding: .utf8) == id, "no new id may be written over the first")
        client.conversion("purchase", value: 9.99, metadata: [:])
        await client.idle()

        #expect(sender.calls == [
            "consent analytics=true marketing=false",
            "event FIRST_OPEN",
            "event signup",
            "event purchase",
        ])
        #expect(sender.consentKeys == [id])
        #expect(sender.events.allSatisfy { $0.anonUserKey == id })
        #expect(sender.events.allSatisfy { $0.consentStatus == .granted })
    }

    // Registering with Apple sends nothing to Trace and no identity anywhere, so it does not wait for consent.
    @Test func theInstallIsRegisteredWithAppleWhateverTheConsentAnswer() async {
        let registrar = FakeRegistrar()
        let sender = RecordingSender()

        await launch(sender, registrar) { $0.setConsent(analytics: false, marketing: false) }

        #expect(registrar.updates == ["0 low"])
        #expect(sender.events.isEmpty)
    }

    @Test func aConversionSetsTheValueFromItsRevenueAndAHostValueIsPassedOn() async {
        let registrar = FakeRegistrar()

        await launch(RecordingSender(), registrar) {
            $0.conversion("purchase", value: 4.99, metadata: [:])
            $0.setConversionValue(fine: 12, coarse: .high)
        }

        #expect(registrar.updates == ["0 low", "16 high", "12 high"])
    }

    // Decided 7 October 2026 (decision 2 of APP_MODELLED_INSTALLS.md in use-trace/trace): the value is set from the
    // conversions of everyone, including people who said no and people who never answered, as Apple designed it.
    // It travels only inside Apple's signed postback, with no identifier. Nothing reaches Trace.
    @Test(arguments: [false, nil] as [Bool?])
    func aConversionSetsTheValueWhateverTheConsentAnswer(answer: Bool?) async {
        let registrar = FakeRegistrar()
        let sender = RecordingSender()

        await launch(sender, registrar) {
            if let answer { $0.setConsent(analytics: answer, marketing: answer) }
            $0.conversion("purchase", value: 4.99, metadata: [:])
        }

        #expect(registrar.updates == ["0 low", "16 high"])
        #expect(sender.events.isEmpty)
    }

    @Test func aPurchaseIsSentAsThePurchaseTypeWithItsValueAndAnythingElseAsCustom() async {
        let sender = RecordingSender()

        await launch(sender) {
            $0.setConsent(analytics: true, marketing: false)
            $0.conversion("Purchase", value: 29.99, metadata: ["plan": "plus"])
            $0.conversion("signup", value: nil, metadata: [:])
        }

        let conversions = sender.events.filter { $0.type != .firstOpen }
        #expect(conversions.map(\.type) == [.purchase, .custom])
        #expect(conversions.map(\.eventName) == ["Purchase", "signup"])
        #expect(conversions.first?.value == 29.99)
        #expect(conversions.first?.metadata == ["plan": "plus"])
    }

    @Test func aConversionWithABlankNameSendsNothing() async {
        let sender = RecordingSender()
        let registrar = FakeRegistrar()

        await launch(sender, registrar) {
            $0.setConsent(analytics: true, marketing: false)
            $0.conversion("  ", value: 1, metadata: [:])
        }

        #expect(sender.calls == ["consent analytics=true marketing=false", "event FIRST_OPEN"])
        #expect(registrar.updates == ["0 low"])
    }

    // Decided 6 October 2026, before the first release: no identifier is stored before consent. The first open waits
    // in memory only; the id and the install are written the moment the person accepts, and a refusal never writes
    // an identifier. The one exception is what the SDK has told Apple: the registration flag, decided the same day,
    // and the conversion value schema's record, decided on 7 October 2026. Neither holds an identifier. These are
    // those decisions as tests, over the directory the SDK writes to.

    /// Every file the SDK has written to its directory.
    private func written() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    /// The two files allowed before an answer, both about what the SDK has told Apple and neither an identifier.
    private let appleFlags = [ConversionValues.registeredFlag, ConversionValues.stateFile].sorted()

    @Test func aFreshInstallThatNeverAnswersWritesTheTwoAppleFilesAndNothingElse() async throws {
        let sender = RecordingSender()
        let registrar = FakeRegistrar()

        await launch(sender, registrar) { $0.conversion("purchase", value: 9.99, metadata: [:]) }

        #expect(try written() == appleFlags,
                "before an answer only the Apple flags may be written: no install id, no first open flag, no queue")
        #expect(sender.calls.isEmpty)
        #expect(InstallId.peek(in: directory) == nil)
        #expect(registrar.updates == ["0 low", "22 high"])
    }

    // The files are on disk so this cannot happen: a second launch registering again would reset the value to fine 0,
    // coarse low, undoing the conversion's medium or a value the host app set for its own schema.
    @Test func aSecondLaunchWithoutAnAnswerDoesNotRegisterWithAppleAgain() async throws {
        await launch(RecordingSender()) { $0.setConversionValue(fine: 42, coarse: .high) }

        let registrar = FakeRegistrar()
        await launch(RecordingSender(), registrar) { $0.conversion("signup", value: nil, metadata: [:]) }

        #expect(registrar.updates.isEmpty, "Apple's value must not be reset or lowered by a later launch")
        #expect(try written() == appleFlags)
    }

    @Test func aRefusalWritesNoIdentifierAndSendsOnlyTheAnswerWithNoIdentifier() async throws {
        let sender = RecordingSender()

        await launch(sender) {
            $0.conversion("purchase", value: 9.99, metadata: [:])
            $0.setConsent(analytics: false, marketing: true)
        }

        #expect(try written() == appleFlags, "a refusal may write no identifier, no first open flag and no queue")
        #expect(InstallId.peek(in: directory) == nil)
        #expect(sender.calls == ["first refusal marketing=true"])
        #expect(sender.consentKeys.isEmpty)
    }

    @Test func acceptanceWritesTheIdSendsExactlyOneFirstOpenWithItThenTheHeldEventsInOrder() async throws {
        let sender = RecordingSender()

        await launch(sender) {
            $0.conversion("signup", value: nil, metadata: [:])
            $0.conversion("purchase", value: 9.99, metadata: [:])
            $0.setConsent(analytics: true, marketing: false)
        }

        let id = try #require(InstallId.peek(in: directory), "the grant should have written the install id")
        #expect(try written() == [TraceClient.firstOpenFlag, InstallId.fileName, ConversionValues.registeredFlag,
                                  ConversionValues.stateFile].sorted())
        #expect(sender.calls == [
            "consent analytics=true marketing=false",
            "event FIRST_OPEN",
            "event signup",
            "event purchase",
        ])
        #expect(sender.consentKeys == [id])
        #expect(sender.events.map(\.anonUserKey) == [id, id, id])
    }

    @Test func aConversionHeldBeforeAcceptanceIsSentAfterIt() async throws {
        let sender = RecordingSender()
        let client = client(sender)
        client.launch()
        client.conversion("purchase", value: 9.99, metadata: [:])
        await client.idle()
        #expect(sender.calls.isEmpty)

        client.setConsent(analytics: true, marketing: false)
        await client.idle()

        let purchase = try #require(sender.events.first { $0.type == .purchase })
        #expect(sender.calls.last == "event purchase")
        #expect(purchase.consentStatus == .granted)
        #expect(purchase.anonUserKey == InstallId.peek(in: directory))
        #expect(purchase.value == 9.99)
    }

    @Test func aRestartBeforeAnyAnswerIsAFirstOpenAgain() async throws {
        await launch(RecordingSender()) { $0.conversion("signup", value: nil, metadata: [:]) }

        // The app is killed with its banner still on screen. Only the Apple files were written, so the next launch
        // knows nothing of this one for Trace: the held conversion is lost, which is the accepted cost, and the
        // install is new. Apple already has it.
        #expect(try written() == appleFlags)

        let sender = RecordingSender()
        let registrar = FakeRegistrar()
        await launch(sender, registrar) { $0.setConsent(analytics: true, marketing: false) }

        #expect(sender.calls == ["consent analytics=true marketing=false", "event FIRST_OPEN"])
        #expect(sender.events.first?.anonUserKey == InstallId.peek(in: directory))
        #expect(registrar.updates.isEmpty, "the first launch registered and recorded it, so this one does not")
    }

    // The server keeps metadata keys of letters, digits and underscores and drops the rest without a word.
    @Test func metadataKeysTheServerWouldDropAreReported() async {
        await launch(RecordingSender()) { $0.conversion("signup", value: nil, metadata: ["ok_key": "1", "bad key": "2"]) }

        #expect(capture.lines.contains { $0.contains("bad key") && !$0.contains("ok_key") })
    }
}
