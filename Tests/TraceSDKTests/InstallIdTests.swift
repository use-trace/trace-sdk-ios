import Foundation
import Testing
@testable import TraceSDK

struct InstallIdTests {

    @Test func theIdIsTheAnonymousKeyShapeTheServerExpects() throws {
        let id = try #require(InstallId.get(in: temporaryDirectory()))
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
            for _ in 0..<32 { group.addTask { InstallId.get(in: directory) ?? "none" } }
            return await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(ids.count == 1)
    }

    // iOS encrypts files until the first unlock after a reboot. An app launched in the background before then, by a
    // push or a background refresh, finds the id file there but cannot read it. Minting a new id then would make one
    // install two, double counted with its journey split, which is worse than sending nothing. A file with no read
    // permission is the same thing as far as the code can tell, so it stands in for the locked phone here.
    @Test func anIdFileThatExistsButCannotBeReadIsNeverReplaced() throws {
        let directory = temporaryDirectory()
        let file = directory.appending(path: InstallId.fileName)
        let original = try #require(InstallId.get(in: directory))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

        #expect(InstallId.read(in: directory) == .unreadable)
        #expect(InstallId.get(in: directory) == nil, "an unreadable id must not be replaced by a new one")
        #expect(InstallId.peek(in: directory) == nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try String(contentsOf: file, encoding: .utf8) == original, "the file must still hold the first id")
        #expect(InstallId.get(in: directory) == original, "once readable, the same install is the same id")
    }

    // An id that could not be stored would be a different id on the next launch: the same double count by
    // another route. So none is handed out at all.
    @Test func anIdThatCannotBeStoredIsNotHandedOut() throws {
        let directory = temporaryDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        #expect(InstallId.get(in: directory) == nil)
        #expect(InstallId.read(in: directory) == .absent)
    }

    // The protection level is a choice, not a default, so it is asserted. Readable from the first unlock after a
    // boot onwards, which is what lets a background send work on a locked phone.
    @Test func theIdFileIsProtectedUntilTheFirstUnlock() {
        #expect(Storage.writingOptions.contains(.completeFileProtectionUntilFirstUserAuthentication))
        #expect(Storage.writingOptions.contains(.atomic))
    }
}
