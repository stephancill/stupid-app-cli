import Foundation
import Testing

@testable import DeviceKit

struct OPackTests {
  @Test("device_info encodes byte-for-byte to the opack2 reference")
  func deviceInfo() {
    let identifier = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEFFFF0000"
    let name = "test-host.local"
    let pairs: [OPackEntry] = [
      OPackEntry(
        key: .string("altIRK"),
        value: .data(
          Data([
            0xE9, 0xE8, 0x2D, 0xC0, 0x6A, 0x49, 0x79, 0x6B, 0x56, 0x6F, 0x54, 0x00, 0x19, 0xB1,
            0xC7, 0x7B,
          ]))),
      OPackEntry(key: .string("btAddr"), value: .string("11:22:33:44:55:66")),
      OPackEntry(key: .string("mac"), value: .data(Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66]))),
      OPackEntry(key: .string("remotepairing_serial_number"), value: .string("AAAAAAAAAAAA")),
      OPackEntry(key: .string("accountID"), value: .string(identifier)),
      OPackEntry(key: .string("model"), value: .string("computer-model")),
      OPackEntry(key: .string("name"), value: .string(name)),
    ]
    let encoded = OPack.encodeDictionary(pairs)
    #expect(
      hex(encoded)
        == "e746616c7449524b80e9e82dc06a49796b566f540019b1c77b466274416464725131313a32323a33333a34343a35353a3636436d6163761122334455665b72656d6f746570616972696e675f73657269616c5f6e756d6265724c414141414141414141414141496163636f756e744944612441414141414141412d424242422d434343432d444444442d454545454646464630303030456d6f64656c4e636f6d70757465722d6d6f64656c446e616d654f746573742d686f73742e6c6f63616c"
    )
  }

  @Test("small integer OPACK uses the compact single-byte form")
  func compactInteger() {
    #expect(OPack.encode(.int(Int64(17))) == Data([0x19]))
    #expect(OPack.encode(.bool(true)) == Data([0x01]))
    #expect(OPack.encode(.bool(false)) == Data([0x02]))
  }

  private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }
}
