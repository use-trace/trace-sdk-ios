import Foundation
import os
import Testing
@testable import TraceSDK

/// Stands in for StoreKit. Records every update it is asked for, and fails each one while `failing` is set.
final class FakeRegistrar: ConversionValueRegistrar {

    struct Failure: Error {}

    private let recorded = OSAllocatedUnfairLock(initialState: [String]())
    private let failing: OSAllocatedUnfairLock<Bool>

    init(failing: Bool = false) {
        self.failing = OSAllocatedUnfairLock(initialState: failing)
    }

    /// One line per update, `fine coarse`, in the order asked for.
    var updates: [String] { recorded.withLock { $0 } }

    func update(fine: Int, coarse: CoarseValue) async throws {
        recorded.withLock { $0.append("\(fine) \(coarse.rawValue)") }
        if failing.withLock({ $0 }) { throw Failure() }
    }
}

/// The conversion value over real files in a temporary directory. A new ``ConversionValues`` over the same directory
/// stands in for a new launch. The schema itself is pinned by ``ConversionValueSchemaTests``; these are the rules
/// around it.
struct ConversionValueTests {

    let directory = temporaryDirectory()
    let capture = LogCapture()
    let clock = FakeClock()

    private func values(_ registrar: FakeRegistrar) -> ConversionValues {
        ConversionValues(directory: directory, registrar: registrar, log: capture.log, now: clock.now)
    }

    // Decided 6 October 2026: the registration flag is written whatever the consent state. Decided 7 October 2026
    // (decision 2 of APP_MODELLED_INSTALLS.md): the schema's record is too, because the value is set from everyone's
    // conversions. Neither holds an identifier, and nothing about consent reaches this type.
    @Test func theFlagAndTheSchemaRecordAreWrittenAsSoonAsAppleTakesTheUpdateWithNoConsentAnswer() async throws {
        let registrar = FakeRegistrar()

        await values(registrar).launched()
        await values(registrar).conversionRecorded(value: nil)

        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
                == [ConversionValues.registeredFlag, ConversionValues.stateFile].sorted())
        #expect(registrar.updates == ["0 low", "1 medium"])
    }

    // The whole reason this file exists: Apple sends no postback unless the app updates the value once.
    @Test func theInstallIsRegisteredOnceOnTheFirstLaunchAndNeverAgain() async {
        let registrar = FakeRegistrar()

        await values(registrar).launched()
        await values(registrar).launched()
        await values(registrar).launched()

        #expect(registrar.updates == ["0 low"])
    }

    // Revenue is summed over the window across launches, so the record has to be on disk: two 2.99 purchases in two
    // launches are 5.98, band 18, not 2.99 twice.
    @Test func revenueFromAnEarlierLaunchIsAddedToNotForgotten() async {
        let registrar = FakeRegistrar()
        await values(registrar).launched()

        await values(registrar).conversionRecorded(value: 2.99)
        await values(registrar).conversionRecorded(value: 2.99)

        #expect(registrar.updates == ["0 low", "12 medium", "18 high"])
    }

    // Rule 3 of the schema: never lowered within a window, so a postback is the window's best.
    @Test func aLaterConversionNeverLowersTheValue() async {
        let registrar = FakeRegistrar()
        await values(registrar).launched()

        await values(registrar).conversionRecorded(value: 50)
        await values(registrar).conversionRecorded(value: nil)
        await values(registrar).conversionRecorded(value: -50)

        #expect(registrar.updates == ["0 low", "37 high", "37 high", "37 high"])
    }

    // Windows 2 and 3 carry the coarse value of their own conversions. A launch in a new window starts it at low,
    // once, and the fine value Apple ignores there is sent as 0.
    @Test func aLaunchInANewWindowStartsItAtLowOnce() async {
        let registrar = FakeRegistrar()
        await values(registrar).launched()
        await values(registrar).conversionRecorded(value: 9.99)

        clock.set(hours: 50)
        await values(registrar).launched()
        await values(registrar).launched()
        await values(registrar).conversionRecorded(value: nil)

        #expect(registrar.updates == ["0 low", "22 high", "0 low", "0 medium"])
    }

    @Test func nothingIsSetThirtyFiveDaysAfterTheFirstLaunch() async {
        let registrar = FakeRegistrar()
        await values(registrar).launched()

        clock.set(hours: 840)
        await values(registrar).launched()
        await values(registrar).conversionRecorded(value: 100)

        #expect(registrar.updates == ["0 low"])
    }

    // 0.1.0 wrote only flags, so an install it registered has no record of when it first launched, and the window a
    // conversion falls in cannot be known. Its value is left as 0.1.0 left it rather than guessed.
    @Test func anInstallRegisteredBeforeTheSchemaIsLeftAlone() async {
        Storage.setFlag(ConversionValues.registeredFlag, in: directory, log: capture.log)
        let registrar = FakeRegistrar()

        await values(registrar).launched()
        await values(registrar).conversionRecorded(value: 9.99)

        #expect(registrar.updates.isEmpty)
    }

    // Before the first unlock after a reboot the record exists and cannot be read. A fresh one written over it would
    // throw the window's revenue away and could lower the value, so nothing is set and nothing written.
    @Test func aRecordThatCannotBeReadIsNeitherUsedNorReplaced() async throws {
        let registrar = FakeRegistrar()
        await values(registrar).launched()
        await values(registrar).conversionRecorded(value: 50)
        let file = directory.appending(path: ConversionValues.stateFile)
        let before = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

        await values(registrar).conversionRecorded(value: 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == before)
        #expect(registrar.updates == ["0 low", "37 high"])
    }

    // The record also remembers that the first consent answer was reported, so it is never reported twice. Neither
    // a registration that only succeeds after the answer nor a new window may forget it.
    @Test func theReportedAnswerSurvivesALateRegistrationAndANewWindow() async {
        let registrar = FakeRegistrar(failing: true)
        await values(registrar).launched()
        ConversionValues.recordAnswerReported(in: directory, log: capture.log)
        await values(registrar).conversionRecorded(value: 9.99)
        #expect(registrar.updates == ["0 low"], "a record started by the answer alone leaves the schema off")

        let working = FakeRegistrar()
        await values(working).launched()
        await values(working).conversionRecorded(value: 9.99)
        clock.set(hours: 50)
        await values(working).launched()

        #expect(working.updates == ["0 low", "22 high", "0 low"])
        #expect(ConversionValues.answerReported(in: directory) == true)
    }

    // StoreKit throws on a fine value outside 0 to 63. Refused here, so the host app sees a log line, not an error.
    @Test(arguments: [-1, 64, 1000, Int.min, Int.max])
    func aFineValueOutsideZeroToSixtyThreeIsRefused(fine: Int) async {
        let registrar = FakeRegistrar()

        await values(registrar).set(fine: fine, coarse: .high)

        #expect(registrar.updates.isEmpty)
        #expect(capture.lines.contains { $0.contains("0 to 63") })
    }

    @Test(arguments: [0, 63])
    func theEndsOfTheRangeAreAccepted(fine: Int) async {
        let registrar = FakeRegistrar()

        await values(registrar).set(fine: fine, coarse: .high)

        #expect(registrar.updates == ["\(fine) high"])
    }

    // A host app with its own schema owns the value from then on, in this launch and every later one. The SDK
    // setting Trace's schema afterwards could lower a value the app had set higher, which SKAdNetwork 4 allows.
    @Test func aValueTheHostAppSetIsNotOverwrittenByALaterConversionOrLaunch() async {
        let registrar = FakeRegistrar()
        await values(registrar).launched()

        await values(registrar).set(fine: 42, coarse: .high)
        await values(registrar).conversionRecorded(value: 1)
        clock.set(hours: 50)
        await values(registrar).launched()
        await values(registrar).conversionRecorded(value: 1)

        #expect(registrar.updates == ["0 low", "42 high"])
    }

    // `launched` does not throw, so the compiler already proves nothing reaches the caller. What this proves is the
    // rest: the failure is logged, and a registration that did not happen is tried again on the next launch rather
    // than recorded as done, because a missed registration means Apple never sends a postback at all.
    @Test func aStoreKitErrorIsLoggedSwallowedAndTriedAgainNextLaunch() async {
        let registrar = FakeRegistrar(failing: true)

        await values(registrar).launched()
        await values(registrar).set(fine: 1, coarse: .low)

        #expect(capture.lines.filter { $0.contains("Apple did not take") }.count == 2)
        await values(registrar).launched()
        #expect(registrar.updates == ["0 low", "1 low", "0 low"])
    }

    // Neither carries an identity, but a backup restored onto a new install would claim a registration that new
    // install never made, and Apple would then send it no postback; and it would bring another install's revenue.
    @Test func theRegistrationFlagAndTheSchemaRecordAreExcludedFromBackup() async throws {
        let registrar = FakeRegistrar()
        await values(registrar).launched()
        await values(registrar).conversionRecorded(value: 1)

        #expect(try isExcludedFromBackup(directory.appending(path: ConversionValues.registeredFlag)) == true)
        #expect(try isExcludedFromBackup(directory.appending(path: ConversionValues.stateFile)) == true)
    }
}
