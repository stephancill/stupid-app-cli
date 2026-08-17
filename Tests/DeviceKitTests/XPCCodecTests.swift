import Foundation
import Testing

@testable import DeviceKit

struct XPCCodecTests {
  struct Fixture {
    var name: String
    var hex: String
    var value: XPCValue
    var flags: UInt32
    var messageID: UInt64

    var bytes: Data {
      var out = Data()
      var i = hex.startIndex
      while i < hex.endIndex {
        let end = hex.index(i, offsetBy: 2)
        out.append(UInt8(hex[i..<end], radix: 16)!)
        i = end
      }
      return out
    }
  }

  private func fixture(
    _ name: String, _ hex: String, _ value: XPCValue, flags: UInt32 = 0x101, messageID: UInt64 = 0
  ) -> Fixture {
    Fixture(name: name, hex: hex, value: value, flags: flags, messageID: messageID)
  }

  @Test("encodes XPC wrappers byte-for-byte against the pinned Python reference")
  func encodesReferenceWrappers() throws {
    let fixtures = [
      fixture(
        "dict",
        "920bb0290101000024000000000000000000000000000000423713420500000000f00000140000000100000061000000009000000200000078000000",
        .dictionary(["a": .string("x")])),
      fixture(
        "empty",
        "920bb0290100000014000000000000000300000000000000423713420500000000f000000400000000000000",
        .dictionary([:]), flags: 0x1, messageID: 3),
      fixture(
        "int64",
        "920bb0290101000024000000000000000000000000000000423713420500000000f0000014000000010000007600000000300000d6ffffffffffffff",
        .dictionary(["v": .int64(-42)])),
      fixture(
        "uint64",
        "920bb0290101000024000000000000000000000000000000423713420500000000f0000014000000010000007600000000400000ffffffffffffffff",
        .dictionary(["v": .uint64(UInt64.max)])),
      fixture(
        "double",
        "920bb0290101000024000000000000000000000000000000423713420500000000f0000014000000010000007600000000500000400c000000000000",
        .dictionary(["v": .double(3.5)])),
      fixture(
        "bool",
        "920bb0290101000020000000000000000000000000000000423713420500000000f000001000000001000000760000000020000001000000",
        .dictionary(["v": .bool(true)])),
      fixture(
        "bool-false",
        "920bb0290101000020000000000000000000000000000000423713420500000000f000001000000001000000760000000020000000000000",
        .dictionary(["v": .bool(false)])),
      fixture(
        "empty-string",
        "920bb0290101000024000000000000000000000000000000423713420500000000f00000140000000100000076000000009000000100000000000000",
        .dictionary(["v": .string("")])),
      fixture(
        "data",
        "920bb0290101000024000000000000000000000000000000423713420500000000f00000140000000100000076000000008000000200000000010000",
        .dictionary(["v": .data(Data([0, 1]))])),
      fixture(
        "null",
        "920bb029010100001c000000000000000000000000000000423713420500000000f000000c000000010000007600000000100000",
        .dictionary(["v": .null])),
      fixture(
        "array",
        "920bb0290101000044000000000000000000000000000000423713420500000000f0000034000000010000007600000000e000002400000003000000003000000100000000000000009000000400000074776f000020000001000000",
        .dictionary(["v": .array([.int64(1), .string("two"), .bool(true)])])),
    ]
    for caseItem in fixtures {
      let encoded = try XPCCodec.encodeWrapper(
        value: caseItem.value,
        messageID: caseItem.messageID,
        flags: caseItem.flags
      )
      #expect(encoded == caseItem.bytes, "\(caseItem.name) mismatch")
    }
  }

  @Test("decodes the full nested reference fixture")
  func decodesNestedReference() throws {
    let hex =
      "920bb02901010100c0000000000000000700000000000000423713420500000000f00000b00000000800000061000000009000000600000068656c6c6f0000006200000000300000d6ffffffffffffff6300000000200000010000006400000000e000001c000000020000000030000001000000000000000030000002000000000000006500000000f0000018000000010000006e65737465640000009000000200000078000000660000000080000003000000010203006700000000500000400c0000000000006800000000400000ffffffffffffffff"
    var data = Data()
    var i = hex.startIndex
    while i < hex.endIndex {
      let end = hex.index(i, offsetBy: 2)
      data.append(UInt8(hex[i..<end], radix: 16)!)
      i = end
    }
    let wrapper = try XPCCodec.decodeWrapper(data)
    #expect(wrapper.messageID == 7)
    let dict = try #require(wrapper.value?.dictionaryValue)
    #expect(dict["a"] == .string("hello"))
    #expect(dict["b"] == .int64(-42))
    #expect(dict["c"] == .bool(true))
    #expect(dict["d"] == .array([.int64(1), .int64(2)]))
    #expect(dict["e"] == .dictionary(["nested": .string("x")]))
    #expect(dict["f"] == .data(Data([1, 2, 3])))
    #expect(dict["g"] == .double(3.5))
    #expect(dict["h"] == .uint64(UInt64.max))
  }

  @Test("rejects malformed and truncated XPC payloads")
  func rejectsMalformed() {
    #expect(throws: XPCCodec.Error.self) {
      try XPCCodec.decodeWrapper(Data([0x11, 0x22]))
    }
    #expect(throws: XPCCodec.Error.self) {
      try XPCCodec.decodeObject(Data([0xff, 0xff, 0xff, 0xff]))
    }
    // Truncated string payload.
    #expect(throws: XPCCodec.Error.self) {
      try XPCCodec.decodeObject(Data([0x00, 0x90, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00]))
    }
  }

  @Test("round-trips every supported value type")
  func roundTrips() throws {
    let values: [XPCValue] = [
      .null,
      .bool(true),
      .bool(false),
      .int64(Int64.min),
      .int64(Int64.max),
      .uint64(UInt64.max),
      .double(-1.25e10),
      .data(Data([0x00, 0xff, 0x01, 0x02, 0x03])),
      .string(""),
      .string("hello world"),
      .string("unicode ✓"),
      .array([]),
      .array([.string("a"), .int64(1)]),
      .dictionary([:]),
      .dictionary(["k": .dictionary(["nested": .array([.bool(false), .null])])]),
    ]
    for value in values {
      let wrapper = try XPCCodec.decodeWrapper(
        XPCCodec.encodeWrapper(value: value, messageID: 9, flags: 0x101)
      )
      #expect(wrapper.value == value)
      #expect(wrapper.messageID == 9)
    }
  }

  @Test("decodes the App Store device peer information shape")
  func decodesPeerInfo() throws {
    let hex =
      "920bb0290101000060010000000000000200000000000000423713420500000000f00000500100000200000050726f70657274696573000000f000009c00000005000000556e6971756544657669636549440000009000000a000000756469642d3030303100000050726f647563745479706500009000000b0000006950686f6e6531352c3200004f5356657273696f6e000000009000000500000032362e31000000004275696c6456657273696f6e00000000009000000400000031413100556e6971756543686970494400000000004000002a0000000000000053657276696365730000000000f000008800000002000000636f6d2e6170706c652e636f72656465766963652e617070736572766963650000f000001800000001000000506f727400000000004000007017000000000000636f6d2e6170706c652e6d6f62696c652e696e7374616c6c6174696f6e5f70726f78790000f000001800000001000000506f727400000000004000007117000000000000"
    var data = Data()
    var i = hex.startIndex
    while i < hex.endIndex {
      let end = hex.index(i, offsetBy: 2)
      data.append(UInt8(hex[i..<end], radix: 16)!)
      i = end
    }
    let wrapper = try XPCCodec.decodeWrapper(data)
    #expect(wrapper.messageID == 2)
    let peerInfo = try #require(wrapper.value?.dictionaryValue)
    let properties = try #require(peerInfo["Properties"]?.dictionaryValue)
    #expect(properties["UniqueDeviceID"] == .string("udid-0001"))
    #expect(properties["ProductType"] == .string("iPhone15,2"))
    let services = try #require(peerInfo["Services"]?.dictionaryValue)
    let appservice = try #require(services["com.apple.coredevice.appservice"]?.dictionaryValue)
    #expect(appservice["Port"] == .uint64(6000))
  }

  @Test("decodes an empty keep-alive wrapper as no payload")
  func decodesEmptyWrapper() throws {
    // A wrapper with an empty payload envelope (stored length 0) is the device
    // keep-alive message that pymobiledevice3 skips (payload is None).
    var data = Data()
    var magic = XPCCodec.wrapperMagic.littleEndian
    withUnsafeBytes(of: &magic) { data.append(contentsOf: $0) }
    var flags = UInt32(0x201).littleEndian
    withUnsafeBytes(of: &flags) { data.append(contentsOf: $0) }
    var length = UInt64(0).littleEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    var messageID = UInt64(4).littleEndian
    withUnsafeBytes(of: &messageID) { data.append(contentsOf: $0) }

    let wrapper = try XPCCodec.decodeWrapper(data)
    #expect(wrapper.value == nil)
    #expect(wrapper.messageID == 4)
  }
}

extension UInt8 {
  init?(_ substring: Substring, radix: Int) {
    guard substring.count == 2, let value = Int(substring, radix: radix), value <= 255 else {
      return nil
    }
    self = UInt8(value)
  }
}
