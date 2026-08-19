import Foundation
import ProjectCore
import Testing

@testable import ProjectCore

struct ReleaseBumperTests {
  private func samplePlist(build: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    \t<key>CFBundleDisplayName</key>
    \t<string>App</string>
    \t<key>CFBundleVersion</key>
    \t<string>\(build)</string>
    \t<key>CFBundleShortVersionString</key>
    \t<string>1.2.0</string>
    </dict></plist>
    """
  }

  @Test("reads the current build number")
  func readsCurrent() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("rb-read-\(UUID().uuidString).plist")
    defer { try? FileManager.default.removeItem(at: url) }
    try samplePlist(build: "42").write(to: url, atomically: true, encoding: .utf8)
    #expect(try ReleaseBumper.currentBuildNumber(at: url) == 42)
  }

  @Test("bumps build number in place and preserves formatting")
  func bumps() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("rb-bump-\(UUID().uuidString).plist")
    defer { try? FileManager.default.removeItem(at: url) }
    let original = samplePlist(build: "42")
    try original.write(to: url, atomically: true, encoding: .utf8)

    let previous = try ReleaseBumper.bumpBuildNumber(inFileAt: url, to: 43)
    #expect(previous == 42)
    let updated = try String(contentsOf: url, encoding: .utf8)
    #expect(updated.contains("\t<string>43</string>"))
    #expect(updated.contains("\t<string>1.2.0</string>"))
    // Formatting (tabs) preserved; only the version changed.
    #expect(updated.filter(\.isNewline).count == original.filter(\.isNewline).count)
  }

  @Test("fails loudly on a non-integer build version")
  func rejectsNonInteger() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("rb-bad-\(UUID().uuidString).plist")
    defer { try? FileManager.default.removeItem(at: url) }
    try samplePlist(build: "1.2b").write(to: url, atomically: true, encoding: .utf8)
    #expect(throws: ReleaseBumper.Error.invalidVersion(string: "1.2b", path: url.path)) {
      _ = try ReleaseBumper.currentBuildNumber(at: url)
    }
  }

  @Test("fails loudly when CFBundleVersion is absent")
  func rejectsMissing() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("rb-none-\(UUID().uuidString).plist")
    defer { try? FileManager.default.removeItem(at: url) }
    try """
    <plist version="1.0"><dict><key>CFBundleDisplayName</key><string>App</string></dict></plist>
    """.write(to: url, atomically: true, encoding: .utf8)
    #expect(throws: ReleaseBumper.Error.versionMissing(url.path)) {
      _ = try ReleaseBumper.currentBuildNumber(at: url)
    }
  }
}