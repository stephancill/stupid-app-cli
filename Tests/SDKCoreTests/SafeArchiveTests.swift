import Foundation
import SDKCore
import Testing

/// Hermetic tests for `SafeArchive.validateEntries`, the security-critical path
/// validation that runs before any SDK archive extraction. No real archive or `tar`
/// process is involved; only the pure entry-validation function is exercised.
struct SafeArchiveTests {
    @Test("accepts nested relative paths")
    func acceptsRelativePaths() throws {
        try SafeArchive.validateEntries([
            "toolset/bin/ld64.lld",
            "Developer/usr/lib/swift/iphoneos/modules/",
            "info.json",
        ])
    }

    @Test("accepts a trailing-slash directory entry")
    func acceptsDirectoryEntry() throws {
        try SafeArchive.validateEntries(["sdk-manifest.json/", "platform"])
    }

    @Test("accepts entries containing a dot-prefixed component name")
    func acceptsDotPrefixedFilename() throws {
        // `._` is rejected (AppleDouble), but a normal file named `.hidden` inside a
        // directory must be allowed.
        try SafeArchive.validateEntries(["Developer/.hidden", "Developer/usr/lib/.DS_Store"])
    }

    @Test("rejects an absolute path entry")
    func rejectsAbsolutePath() {
        #expect(throws: SafeArchive.Error.self) {
            try SafeArchive.validateEntries(["/etc/passwd"])
        }
    }

    @Test("rejects a leading traversal entry")
    func rejectsLeadingTraversal() {
        #expect(throws: SafeArchive.Error.self) {
            try SafeArchive.validateEntries(["../escape"])
        }
    }

    @Test("rejects nested traversal anywhere in the path")
    func rejectsNestedTraversal() {
        #expect(throws: SafeArchive.Error.self) {
            try SafeArchive.validateEntries(["toolset/../../escape", "a/../b/../../c"])
        }
    }

    @Test("rejects a leading dot-dot component")
    func rejectsDotDotComponent() {
        #expect(throws: SafeArchive.Error.self) {
            try SafeArchive.validateEntries(["../Developer"])
        }
    }

    @Test("rejects a '.' component that aliases the root")
    func rejectsDotComponent() {
        #expect(throws: SafeArchive.Error.self) {
            try SafeArchive.validateEntries(["./info.json", "toolset/./x"])
        }
    }

    @Test("rejects AppleDouble metadata entries")
    func rejectsAppleDouble() {
        #expect(throws: SafeArchive.Error.self) {
            try SafeArchive.validateEntries(["Developer/._Info.plist", "._info.json"])
        }
    }

    @Test("rejects drive-letter style entries")
    func rejectsDriveLetter() {
        #expect(throws: SafeArchive.Error.self) {
            try SafeArchive.validateEntries(["C:/Windows", "D:"])
        }
    }

    @Test("rejects a drive-letter first component with a trailing colon")
    func rejectsColonFirstComponent() {
        #expect(throws: SafeArchive.Error.self) {
            try SafeArchive.validateEntries(["C:/evil"])
        }
    }
}
