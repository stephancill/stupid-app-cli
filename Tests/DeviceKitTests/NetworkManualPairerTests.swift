import Foundation
import Testing

@testable import DeviceKit

/// The RPPairing JSON <-> XPC bridge the network pairer uses to drive the shared
/// CoreDevice Pair-Setup code.
struct NetworkManualPairerTests {
  @Test("outgoing XPC data becomes base64 JSON and incoming pairing data becomes XPC data")
  func bridgesBinaryValues() throws {
    let payload = Data([0x06, 0x01, 0x02])
    let outgoing = NetworkManualPairer.jsonObject(
      .dictionary(["data": .data(payload), "sequenceNumber": .uint64(3), "flag": .bool(true)]))
      as? [String: Any]
    #expect(outgoing?["data"] as? String == payload.base64EncodedString())

    let frame = try JSONSerialization.jsonObject(
      with: Data(
        """
        {"message":{"plain":{"_0":{"event":{"_0":{"pairingData":{"_0":{"data":"\(payload.base64EncodedString())","kind":"setupManualPairing","startNewSession":false}}}}}},
         "streamEncrypted":{"_0":"\(payload.base64EncodedString())"}},
         "sequenceNumber":2}
        """.utf8)) as! [String: Any]
    let incoming = NetworkManualPairer.xpcDictionary(frame)
    let node = incoming["message"]?.dictionaryValue?["plain"]?.dictionaryValue?["_0"]?
      .dictionaryValue?["event"]?.dictionaryValue?["_0"]?.dictionaryValue?["pairingData"]?
      .dictionaryValue?["_0"]?.dictionaryValue
    #expect(node?["data"]?.dataValue == payload)
    #expect(node?["kind"]?.stringValue == "setupManualPairing")
    #expect(node?["startNewSession"] == .bool(false))
    #expect(
      incoming["message"]?.dictionaryValue?["streamEncrypted"]?.dictionaryValue?["_0"]?
        .dataValue == payload)
    #expect(incoming["sequenceNumber"] == .int64(2))
  }
}
