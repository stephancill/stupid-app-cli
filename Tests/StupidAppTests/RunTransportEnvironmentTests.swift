import Foundation
import Testing

@testable import stupid_app

struct RunTransportEnvironmentTests {
  @Test("Wireless deployment never resolves or executes sudo")
  func wirelessWithoutHelper() throws {
    let command = try RunCommand.parse([
      "--network", "--udid", "test-device", "--sudo", "/nonexistent/sudo",
    ])
    try command.validateTransportEnvironment(
      pairingDirectory: URL(fileURLWithPath: "/nonexistent/pairing"))
  }

  @Test("USB deployment still validates the explicit privilege boundary")
  func usbRetainsHelper() throws {
    let command = try RunCommand.parse(["--usb", "--sudo", "/nonexistent/sudo"])
    #expect(throws: (any Error).self) {
      try command.validateTransportEnvironment(
        pairingDirectory: URL(fileURLWithPath: "/nonexistent/pairing"))
    }
  }
}
