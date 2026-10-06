import Testing
@testable import TraceSDK

@Test func versionIsANonEmptySemanticVersion() {
    let parts = TraceSDKVersion.current.split(separator: ".", omittingEmptySubsequences: false)
    #expect(parts.count == 3)
    #expect(parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
}

// DELIBERATE VIOLATION, reverted in the next commit: fails only on iOS, so only test ios can see it.
#if os(iOS)
@Test func failsOnlyOnTheSimulator() {
    #expect(Bool(false), "deliberate failure to prove test ios runs iOS only code")
}
#endif
