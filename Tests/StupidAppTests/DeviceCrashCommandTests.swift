import Foundation
import Testing

@testable import stupid_app

struct DeviceCrashCommandTests {
  private func writeFixture(_ buffer: String) throws -> (path: String, cleanup: () -> Void) {
    let dir = try FileManager.default.temporaryDirectory.appendingPathComponent(
      "crash-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("sample.ips")
    try Data(buffer.utf8).write(to: url)
    return (url.path, { try? FileManager.default.removeItem(at: dir) })
  }

  @Test("load surfaces a watchdog termination summary")
  func watchdogSummary() throws {
    let (path, cleanup) = try writeFixture(
      """
      {"bug_type":"298","name":"TorrentApp","os_version":"iPhone OS 26.3 (21E230)"}
      {"exception":{"type":"EXC_BAD_ACCESS","subtype":"KERN_INVALID_ADDRESS"},"termination":{"namespace":"JETSAM","indicator":"61f","code":"0"}}
      """)
    defer { cleanup() }
    let report = try DeviceCrashCommand.load(path: path)
    let summary = report.summary()
    #expect(summary.contains("Termination: JETSAM (0) — 61f"))
    #expect(summary.contains("watchdog / resource-limit termination"))
  }

  @Test("jsonString emits machine-readable fields")
  func jsonOutput() throws {
    let (path, cleanup) = try writeFixture(
      """
      {"bug_type":"298","name":"App"}
      {"termination":{"namespace":"JETSAM","code":"0","reason":"CPU"}}
      """)
    defer { cleanup() }
    let report = try DeviceCrashCommand.load(path: path)
    let json = DeviceCrashCommand.jsonString(of: report)
    #expect(json.contains("\"bugType\""))
    #expect(json.contains("\"298\""))
    #expect(json.contains("\"JETSAM\""))
  }

  @Test("missing path errors loudly")
  func missingPathFails() {
    #expect(throws: DeviceCrashError.self) {
      try DeviceCrashCommand.load(path: nil)
    }
  }

  @Test("unreadable path errors loudly")
  func unreadablePathFails() {
    #expect(throws: DeviceCrashError.self) {
      try DeviceCrashCommand.load(path: "/nonexistent/does/not/exist.ips")
    }
  }
}