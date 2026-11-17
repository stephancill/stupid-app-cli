import Foundation
import Testing

@testable import SigningKit

/// The native ad-hoc signature (simulator builds on Linux) must be what Apple's own
/// `codesign` accepts. On macOS this builds a real arm64 simulator executable, signs it
/// natively and has `codesign --verify --strict` check it.
@Suite("Native ad-hoc signing")
struct NativeAdHocSignerTests {
  @Test("codesign accepts a native ad-hoc signature", arguments: [false, true])
  func codesignVerifies(withEntitlements: Bool) throws {
    #if os(macOS)
      let fileManager = FileManager.default
      let root = fileManager.temporaryDirectory.appendingPathComponent(
        "adhoc-\(UUID().uuidString)", isDirectory: true)
      defer { try? fileManager.removeItem(at: root) }
      let app = root.appendingPathComponent("Fixture.app", isDirectory: true)
      try fileManager.createDirectory(at: app, withIntermediateDirectories: true)

      let source = root.appendingPathComponent("main.c")
      try Data("int main(void) { return 0; }\n".utf8).write(to: source)
      let executable = app.appendingPathComponent("Fixture")
      let compile = try run(
        "/usr/bin/xcrun",
        ["--sdk", "iphonesimulator", "clang", "-target", "arm64-apple-ios17.0-simulator",
         source.path, "-o", executable.path])
      #expect(compile.status == 0, "\(compile.output)")

      let info: [String: Any] = [
        "CFBundleExecutable": "Fixture", "CFBundleIdentifier": "net.example.fixture",
        "CFBundlePackageType": "APPL", "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
      ]
      try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Info.plist"))
      try Data("resource".utf8).write(to: app.appendingPathComponent("resource.txt"))

      let entitlements: [String: Any] =
        withEntitlements
        ? ["get-task-allow": true, "com.apple.security.application-groups": ["group.fixture"]]
        : [:]
      try NativeSigner().adHocSign(appBundle: app, entitlements: entitlements)

      let verify = try run("/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", app.path])
      #expect(verify.status == 0, "\(verify.output)")
      let describe = try run("/usr/bin/codesign", ["-dvvv", app.path])
      #expect(describe.output.contains("Signature=adhoc"), "\(describe.output)")
      #expect(describe.output.contains("Identifier=net.example.fixture"), "\(describe.output)")
      #expect(describe.output.contains("TeamIdentifier=not set"), "\(describe.output)")
      if withEntitlements {
        let shown = try run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", app.path])
        #expect(shown.output.contains("group.fixture"), "\(shown.output)")
      }
    #endif
  }

  private func run(_ executable: String, _ arguments: [String]) throws -> (
    status: Int32, output: String
  ) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }
}
