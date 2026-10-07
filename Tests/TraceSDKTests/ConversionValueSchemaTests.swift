import Foundation
import os
import Testing
@testable import TraceSDK

/// The test vectors both sides of Trace's conversion value schema must pass: this SDK, which sets the value, and the
/// server, which reads Apple's postbacks with the same schema (`conversionValueFor` in `apps/api/src/app-reports/`
/// in `use-trace/trace`). The file is copied into both repositories and the copies must match.
struct ConversionValueSchemaTests {

    struct Vectors: Decodable {
        struct Conversion: Decodable {
            let hours: Double
            let value: Double?
        }
        struct Expected: Decodable, Equatable {
            let fine: Int
            let coarse: [String]
        }
        struct Vector: Decodable {
            let name: String
            let conversions: [Conversion]
            let expected: Expected
        }
        let schema_version: Int
        let window_end_hours: [Double]
        let high_revenue: Double
        let fine_band_lower_edges: [Double]
        let vectors: [Vector]
    }

    static let file: Vectors = {
        let url = Bundle.module.url(forResource: "conversion-value-vectors", withExtension: "json")!
        return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }()

    // The constants are in the code, not read from the file at run time, so the file pins them.
    @Test func theSchemaInTheCodeIsTheSchemaInTheFile() {
        #expect(ConversionValueSchema.version == Self.file.schema_version)
        #expect(ConversionValueSchema.windowEnds == Self.file.window_end_hours.map { $0 * 3600 })
        #expect(ConversionValueSchema.highRevenue == Self.file.high_revenue)
        #expect(ConversionValueSchema.fineBandLowerEdges == Self.file.fine_band_lower_edges)
        #expect(ConversionValueSchema.fineBandLowerEdges.count == 61, "bands 3 to 63, one edge each")
    }

    /// Each vector run through the real ``ConversionValues`` over a real directory, as an install would live it: a
    /// first launch, a launch at the start of windows 2 and 3, and each conversion at its hour, each launch a new
    /// ``ConversionValues`` over the same files. What Apple holds at the end of a window is the last value set in it.
    @Test(arguments: Self.file.vectors.map(\.name))
    func theSDKSetsWhatTheVectorSays(name: String) async throws {
        let vector = try #require(Self.file.vectors.first { $0.name == name })
        let directory = temporaryDirectory()
        let clock = FakeClock()
        let registrar = FakeRegistrar()
        func values() -> ConversionValues {
            ConversionValues(directory: directory, registrar: registrar, now: clock.now)
        }

        // Launches before conversions at the same hour, because an app is open before anything happens in it.
        enum Step { case launch, conversion(Double?) }
        let steps = ([(0.0, Step.launch), (48, .launch), (168, .launch)] + vector.conversions.map { ($0.hours, .conversion($0.value)) })
            .enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element)

        var lastInWindow: [Int: String] = [:]
        for (hours, step) in steps {
            clock.set(hours: hours)
            let before = registrar.updates.count
            switch step {
            case .launch: await values().launched()
            case .conversion(let value): await values().conversionRecorded(value: value)
            }
            if registrar.updates.count > before, let window = [48.0, 168, 840].firstIndex(where: { hours < $0 }) {
                lastInWindow[window] = registrar.updates.last
            }
        }

        let windowOne = try #require(lastInWindow[0]).split(separator: " ")
        let actual = Vectors.Expected(
            fine: Int(windowOne[0])!,
            coarse: (0...2).map { lastInWindow[$0]?.split(separator: " ").last.map(String.init) ?? "nothing set" })
        #expect(actual == vector.expected)
    }
}

/// A clock a test moves by hand, in hours after a fixed first launch.
final class FakeClock: Sendable {
    private let start = Date(timeIntervalSince1970: 1_791_331_200)
    private let current: OSAllocatedUnfairLock<Date>

    init() { current = OSAllocatedUnfairLock(initialState: start) }

    var now: @Sendable () -> Date { { [current] in current.withLock { $0 } } }

    func set(hours: Double) { current.withLock { $0 = start.addingTimeInterval(hours * 3600) } }
}
