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

/// The conversion value over real flag files in a temporary directory. A new ``ConversionValues`` over the same
/// directory stands in for a new launch.
struct ConversionValueTests {

    let directory = temporaryDirectory()
    let capture = LogCapture()

    private func values(_ registrar: FakeRegistrar) -> ConversionValues {
        ConversionValues(directory: directory, registrar: registrar, log: capture.log)
    }

    // The whole reason this file exists: Apple sends no postback unless the app updates the value once.
    @Test func theInstallIsRegisteredOnceOnTheFirstLaunchAndNeverAgain() async {
        let registrar = FakeRegistrar()

        await values(registrar).registerInstall()
        await values(registrar).registerInstall()
        await values(registrar).registerInstall()

        #expect(registrar.updates == ["0 low"])
    }

    @Test func theFirstConversionRaisesTheCoarseValueToMediumAndOnlyTheFirst() async {
        let registrar = FakeRegistrar()
        await values(registrar).registerInstall()

        await values(registrar).conversionRecorded()
        await values(registrar).conversionRecorded()

        #expect(registrar.updates == ["0 low", "0 medium"])
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

    // A host app with its own schema owns the value from then on. The SDK raising it to medium afterwards could
    // lower a value the app had set higher, which SKAdNetwork 4 allows.
    @Test func aValueTheHostAppSetIsNotOverwrittenByALaterConversion() async {
        let registrar = FakeRegistrar()
        await values(registrar).registerInstall()

        await values(registrar).set(fine: 42, coarse: .high)
        await values(registrar).conversionRecorded()

        #expect(registrar.updates == ["0 low", "42 high"])
    }

    // `registerInstall` does not throw, so the compiler already proves nothing reaches the caller. What this proves
    // is the rest: the failure is logged, and a registration that did not happen is tried again on the next launch
    // rather than recorded as done, because a missed registration means Apple never sends a postback at all.
    @Test func aStoreKitErrorIsLoggedSwallowedAndTriedAgainNextLaunch() async {
        let registrar = FakeRegistrar(failing: true)

        await values(registrar).registerInstall()
        await values(registrar).conversionRecorded()
        await values(registrar).set(fine: 1, coarse: .low)

        #expect(capture.lines.filter { $0.contains("Apple did not take") }.count == 3)
        await values(registrar).registerInstall()
        #expect(registrar.updates == ["0 low", "0 medium", "1 low", "0 low"])
    }

    // The flag carries no identity, but a backup restored onto a new install would claim a registration that new
    // install never made, and Apple would then send it no postback.
    @Test func theRegistrationFlagIsExcludedFromBackup() async throws {
        await values(FakeRegistrar()).registerInstall()

        #expect(try isExcludedFromBackup(directory.appending(path: ConversionValues.registeredFlag)) == true)
    }
}
