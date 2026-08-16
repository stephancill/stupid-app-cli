import Foundation
import Testing

@testable import DeviceKit

/// Unit tests for the pymobiledevice3 USB installer wrapper. No device or tooling is
/// required; binary resolution, parsing, timeout, and redaction are exercised.
struct PyMobileDevice3InstallerTests {
  @Test("missing installer binary fails loudly")
  func missingBinary() {
    let installer = PyMobileDevice3Installer(executablePath: "/nonexistent/pymobiledevice3")
    #expect(throws: PyMobileDevice3Installer.Error.self) {
      try installer.usbDeviceUDIDs()
    }
  }

  @Test("parses simple UDID list output")
  func parsesUDIDList() {
    let output = "00008100-0000000000000000\n\n00008101-0000000000000000\n"
    let udids = PyMobileDevice3Installer.parseUDIDList(output)
    #expect(udids == ["00008100-0000000000000000", "00008101-0000000000000000"])
  }

  @Test("parses pymobiledevice3 JSON UDID list output")
  func parsesJSONUDIDList() {
    let output = "[\n  \"00008100-0000000000000000\"\n]\n"
    #expect(PyMobileDevice3Installer.parseUDIDList(output) == ["00008100-0000000000000000"])
  }

  @Test("empty output yields no devices")
  func emptyOutput() {
    #expect(PyMobileDevice3Installer.parseUDIDList("").isEmpty)
  }

  @Test("installer timeout is phase-specific")
  func installTimeoutIsActionable() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("pymobiledevice3")
    try
      "#!/bin/sh\nprintf 'device %s stalled\\n' \"$*\" >&2\ntrap '' INT TERM\nwhile :; do :; done\n"
      .write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    let udid = "00008100-PRIVATE-DEVICE-ID"
    let installer = PyMobileDevice3Installer(
      executablePath: executable.path,
      installTimeoutSeconds: 0.2
    )

    do {
      try installer.install(ipa: directory.appendingPathComponent("App.ipa"), udid: udid)
      Issue.record("Expected installation to time out")
    } catch let error as PyMobileDevice3Installer.Error {
      let description = error.description
      #expect(description.contains("Installation failed"))
      #expect(description.contains("timed out"))
    }
  }

  @Test("selected device UDID is redacted from diagnostics")
  func redactsSelectedUDID() {
    let udid = "00008100-PRIVATE-DEVICE-ID"
    let detail = PyMobileDevice3Installer.redact(
      detail: "Mux connection to \(udid) failed", udid: udid)

    #expect(detail == "Mux connection to <device-udid> failed")
  }
}
