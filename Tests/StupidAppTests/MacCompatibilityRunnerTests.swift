import Foundation
import Testing

@testable import stupid_app

@Suite("Mac compatibility runner")
struct MacCompatibilityRunnerTests {
  @Test("selects the available physical Mac")
  func selectsLocalMac() throws {
    let data = Data(
      """
      {
        "SPHardwareDataType": [
          {
            "machine_name": "My Mac",
            "provisioning_UDID": "MAC"
          }
        ]
      }
      """.utf8)

    let device = try MacCompatibilityRunner.decodeLocalDevice(data)

    #expect(device.identifier == "MAC")
    #expect(device.name == "My Mac")
  }

  @Test("rejects an unavailable Mac")
  func rejectsUnavailableMac() throws {
    let data = Data(
      """
      { "SPHardwareDataType": [] }
      """.utf8)

    #expect(throws: MacCompatibilityRunner.Error.self) {
      try MacCompatibilityRunner.decodeLocalDevice(data)
    }
  }

  @Test("enumerates nested app extensions in a deep wrapper")
  func enumeratesNestedAppExtensions() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let plugins = dir.appendingPathComponent("PlugIns", isDirectory: true)
    let safari = plugins.appendingPathComponent("Safari.appex", isDirectory: true)
    let widget = plugins.appendingPathComponent("Widget.appex", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: safari, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: widget, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: plugins.appendingPathComponent("Assets", isDirectory: true), withIntermediateDirectories: true)

    let found = MacCompatibilityRunner.enumerateNestedAppExtensions(in: dir)

    #expect(found.map(\.lastPathComponent) == ["Safari.appex", "Widget.appex"])
  }

  @Test("reports no nested app extensions when PlugIns is absent")
  func reportsNoNestedExtensions() {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(MacCompatibilityRunner.enumerateNestedAppExtensions(in: dir).isEmpty)
  }
}
