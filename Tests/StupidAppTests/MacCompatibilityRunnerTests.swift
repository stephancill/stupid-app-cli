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
}
