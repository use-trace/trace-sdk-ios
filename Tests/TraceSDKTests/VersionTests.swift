import Testing
@testable import TraceSDK

@Test func versionIsANonEmptySemanticVersion() {
    let parts = TraceSDKVersion.current.split(separator: ".", omittingEmptySubsequences: false)
    #expect(parts.count == 3)
    #expect(parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
}
