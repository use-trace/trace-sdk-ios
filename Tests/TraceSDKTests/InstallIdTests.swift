import Foundation
import Testing
@testable import TraceSDK

struct InstallIdTests {

    @Test func theIdIsTheAnonymousKeyShapeTheServerExpects() {
        let id = InstallId.get(in: temporaryDirectory())
        #expect(id.wholeMatch(of: /auk_app_[0-9a-f]{32}/) != nil)
    }

    @Test func theIdIsStableAcrossCalls() {
        let directory = temporaryDirectory()
        let first = InstallId.get(in: directory)
        #expect(InstallId.get(in: directory) == first)
        #expect(InstallId.peek(in: directory) == first)
    }

    @Test func twoInstallsAreTwoDifferentIds() {
        #expect(InstallId.get(in: temporaryDirectory()) != InstallId.get(in: temporaryDirectory()))
    }

    @Test func peekIsNilBeforeGetAndDoesNotCreateAnId() {
        let directory = temporaryDirectory()
        #expect(InstallId.peek(in: directory) == nil)
        #expect(InstallId.peek(in: directory) == nil, "a peek must not mint an id for the next peek to find")
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "install_id").path))
    }

    @Test func theDefaultDirectoryIsInApplicationSupport() {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #expect(Storage.defaultDirectory.standardizedFileURL.path.hasPrefix(applicationSupport.standardizedFileURL.path + "/"))
    }

    @Test func theIdIsOneFileInTheGivenDirectory() throws {
        let directory = temporaryDirectory().appending(path: "not-yet-created")
        let id = InstallId.get(in: directory)
        let stored = try String(contentsOf: directory.appending(path: "install_id"), encoding: .utf8)
        #expect(stored == id)
    }

    /// The reason the id is a file and not a Keychain item or a default: it must not come back after a reinstall,
    /// and a backup restored onto a new install would bring it back. Read from disk, not trusted from the setter.
    @Test func theIdFileIsExcludedFromBackup() throws {
        let directory = temporaryDirectory()
        _ = InstallId.get(in: directory)
        #expect(try isExcludedFromBackup(directory.appending(path: "install_id")) == true)
    }

    @Test func manyThreadsAskingAtOnceGetOneId() async {
        let directory = temporaryDirectory()
        let ids = await withTaskGroup(of: String.self) { group in
            for _ in 0..<32 { group.addTask { InstallId.get(in: directory) } }
            return await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(ids.count == 1)
    }
}
