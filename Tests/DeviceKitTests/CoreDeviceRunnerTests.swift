import Foundation
import Testing

@testable import DeviceKit

struct CoreDeviceRunnerTests {
  @Test("missing Python fails before invoking the helper")
  func missingPython() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = CoreDeviceRunner(
      pythonPath: directory.appendingPathComponent("missing-python").path,
      pairingDirectory: directory.appendingPathComponent("pairing")
    )

    #expect(throws: CoreDeviceRunner.Error.self) {
      try runner.validateEnvironment(requirePrivileges: false)
    }
  }

  @Test("helper receives one combined network deployment operation")
  func combinedNetworkOperation() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("python")
    let argumentsFile = directory.appendingPathComponent("arguments")
    let pairingDirectory = directory.appendingPathComponent("pairing")
    try """
    #!/bin/sh
    printf '%s\n' "$@" > "\(argumentsFile.path)"
    test "$STUPID_APP_PAIRING_HOME" = "\(pairingDirectory.path)" || exit 12
    printf '{"status":"ok"}\n'
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executable.path
    )

    let udid = "00008100-PRIVATE-DEVICE-ID"
    let runner = CoreDeviceRunner(
      pythonPath: executable.path,
      pairingDirectory: pairingDirectory,
      discoveryTimeoutSeconds: 2,
      installTimeoutSeconds: 3,
      launchTimeoutSeconds: 4
    )
    try runner.installAndLaunchNetwork(
      ipa: directory.appendingPathComponent("App.ipa"),
      bundleID: "net.example.app",
      udid: udid
    )

    let arguments = try String(contentsOf: argumentsFile, encoding: .utf8)
    #expect(arguments.contains("pymobiledevice3_helper.py"))
    #expect(arguments.contains("run-network"))
    #expect(arguments.contains("--install-timeout\n3"))
    #expect(arguments.contains("--launch-timeout\n4"))
    #expect(arguments.contains(udid))
    let attributes = try FileManager.default.attributesOfItem(atPath: pairingDirectory.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  }

  @Test("sudo invocation explicitly preserves only the pairing-home setting")
  func explicitSudoInvocation() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let python = directory.appendingPathComponent("python")
    let sudo = directory.appendingPathComponent("sudo")
    let helper = directory.appendingPathComponent("helper.py")
    let argumentsFile = directory.appendingPathComponent("sudo-arguments")
    try "#!/bin/sh\nexit 0\n".write(to: python, atomically: true, encoding: .utf8)
    try "# installed helper\n".write(to: helper, atomically: true, encoding: .utf8)
    try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"\(argumentsFile.path)\"\n".write(
      to: sudo,
      atomically: true,
      encoding: .utf8
    )
    for executable in [python, sudo] {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: executable.path
      )
    }

    let runner = CoreDeviceRunner(
      pythonPath: python.path,
      sudoPath: sudo.path,
      helperPath: helper.path,
      pairingDirectory: directory.appendingPathComponent("pairing")
    )
    try runner.validateEnvironment(requirePrivileges: true)

    let arguments = try String(contentsOf: argumentsFile, encoding: .utf8)
    #expect(arguments.hasPrefix("--preserve-env=STUPID_APP_PAIRING_HOME\n"))
    #expect(arguments.contains("\(python.path)\n"))
    #expect(arguments.contains("\(helper.path)\n"))
    #expect(arguments.contains("check\n--require-root"))
  }

  @Test("selected device identifier is redacted from helper diagnostics")
  func redaction() {
    let udid = "00008100-PRIVATE-DEVICE-ID"
    #expect(
      CoreDeviceRunner.redact(detail: "Tunnel for \(udid) failed", udid: udid)
        == "Tunnel for <device-udid> failed"
    )
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
