import Foundation
import Testing

@testable import DeviceKit

struct RemotepairingDiscoveryTests {
  @Test("DNS names encode and decode round-trip")
  func nameRoundTrip() throws {
    let name = "_remotepairing._tcp.local."
    let encoded = RemotepairingDiscovery.encodeName(name)
    // 14 chars, 4 chars, 5 chars labels + three zero-length terminators
    #expect(encoded.count == 1 + 14 + 1 + 4 + 1 + 5 + 1)
    let decoded = try RemotepairingDiscovery.decodeName(encoded, offset: 0)
    #expect(decoded.name == name)
    #expect(decoded.next == encoded.count)
  }

  @Test("DNS name compression pointers are followed")
  func nameCompression() throws {
    // A base name followed by a name that is simply a pointer to offset 0.
    let data =
      Data([0x0E]) + Data("_remotepairing".utf8)
      + Data([0x04]) + Data("_tcp".utf8)
      + Data([0x05]) + Data("local".utf8)
      + Data([0x00])  // end of base name
      + Data([0xC0, 0x00])  // pointer to offset 0
    let base = try RemotepairingDiscovery.decodeName(data, offset: 0)
    #expect(base.name == "_remotepairing._tcp.local.")
    #expect(base.next == 27)
    let pointer = try RemotepairingDiscovery.decodeName(data, offset: 27)
    #expect(pointer.name == "_remotepairing._tcp.local.")
    #expect(pointer.next == 29)
  }

  @Test("PTR query has one question for the service type")
  func buildQuery() throws {
    let query = RemotepairingDiscovery.buildPTRQuery("_remotepairing._tcp.local.")
    #expect(query.count >= 12 + 1 + 17 + 4)
    #expect(RemotepairingDiscovery.bigEndianUInt16(query, at: 4) == 1)  // one question
    #expect(query[12] == 0x0E)  // first name label = "_remotepairing" (14 chars)
  }

  @Test("records parse PTR, SRV, TXT, A, and AAAA from one message")
  func parseRecords() throws {
    let service = "_remotepairing._tcp.local."
    let instance = "iPhone._remotepairing._tcp.local."
    let host = "device.local."

    var message = Data()
    appendBig16(0, to: &message)  // id
    appendBig16(0, to: &message)  // flags
    appendBig16(1, to: &message)  // qd
    appendBig16(3, to: &message)  // an: PTR, SRV, TXT
    appendBig16(0, to: &message)  // ns
    appendBig16(2, to: &message)  // ar: A, AAAA
    // question
    message.append(RemotepairingDiscovery.encodeName(service))
    appendBig16(12, to: &message)
    appendBig16(0x0001, to: &message)

    // PTR: name=service, rdata=instance name
    appendRR(service, type: 12, rdata: RemotepairingDiscovery.encodeName(instance), to: &message)
    // SRV: name=instance, rdata = pri+weight+port+host name
    var srvRdata = Data()
    appendBig16(0, to: &srvRdata)
    appendBig16(0, to: &srvRdata)
    appendBig16(62079, to: &srvRdata)
    srvRdata.append(RemotepairingDiscovery.encodeName(host))
    appendRR(instance, type: 33, rdata: srvRdata, to: &message)
    // TXT: name=instance
    var txtData = Data()
    txtData.append(0x07)
    txtData.append(Data("txtvers".utf8))
    txtData.append(0x07)
    txtData.append(Data("rpBA=AA".utf8))
    appendRR(instance, type: 16, rdata: txtData, to: &message)
    // A: host
    appendRR(host, type: 1, rdata: Data([192, 168, 1, 20]), to: &message)
    // AAAA: host
    appendRR(host, type: 28, rdata: ipv6Bytes("2001:db8::1"), to: &message)

    let records = try RemotepairingDiscovery.parseRecords(message)
    let ptr = records.first { $0.type == 12 }
    #expect(ptr?.ptrTarget == instance)
    let srv = records.first { $0.type == 33 }
    #expect(srv?.srv?.port == 62079)
    #expect(srv?.srv?.target == host)
    let txt = records.first { $0.type == 16 }
    #expect(txt?.txt?["rpBA"] == "AA")
    let a = records.first { $0.type == 1 }
    #expect(a?.address == "192.168.1.20")
    let aaaa = records.first { $0.type == 28 }
    #expect(aaaa?.address == "2001:db8::1")
  }

  private func appendRR(_ name: String, type: UInt16, rdata: Data, to message: inout Data) {
    message.append(RemotepairingDiscovery.encodeName(name))
    appendBig16(type, to: &message)
    appendBig16(0x0001, to: &message)
    appendBig32(120, to: &message)
    appendBig16(UInt16(rdata.count), to: &message)
    message.append(rdata)
  }

  @Test("assemble groups PTR/SRV/TXT/A records into advertisements")
  func assemble() throws {
    let service = "_remotepairing._tcp.local."
    let instance = "iPhone._remotepairing._tcp.local."
    let host = "device.local."
    var records: [RemotepairingDiscovery.Record] = []
    records.append(recordHelper(type: 12, name: service, ptr: instance))
    records.append(recordHelper(type: 33, name: instance, srv: (0, 0, 62079, host)))
    records.append(recordHelper(type: 16, name: instance, txt: ["txtvers": "1"]))
    records.append(recordHelper(type: 1, name: host, address: "192.168.1.20"))
    records.append(recordHelper(type: 28, name: host, address: "2001:db8::1"))

    let result = RemotepairingDiscovery.assemble(records)
    #expect(result.count == 1)
    let advertisement = result[0]
    #expect(advertisement.instance == instance)
    #expect(advertisement.host == "device.local")
    #expect(advertisement.port == 62079)
    #expect(advertisement.properties["txtvers"] == "1")
    #expect(advertisement.addresses.count == 2)
    // Link-local IPv4 sorts before IPv6.
    #expect(advertisement.addresses.first?.ip == "192.168.1.20")
  }

  private func appendBig16(_ value: UInt16, to data: inout Data) {
    RemotepairingDiscovery.appendBigEndian(value, to: &data)
  }

  private func appendBig32(_ value: UInt32, to data: inout Data) {
    RemotepairingDiscovery.appendBigEndian(value, to: &data)
  }

  private func ipv6Bytes(_ text: String) -> Data {
    var buffer = [UInt8](repeating: 0, count: 16)
    _ = text.withCString { inet_pton(AF_INET6, $0, &buffer) }
    return Data(buffer)
  }

  private func recordHelper(
    type: UInt16, name: String, ptr: String? = nil,
    srv: (UInt16, UInt16, UInt16, String)? = nil,
    txt: [String: String]? = nil, address: String? = nil
  ) -> RemotepairingDiscovery.Record {
    RemotepairingDiscovery.Record(
      name: name, type: type, ttl: 120,
      ptrTarget: ptr,
      srv: srv.map { (priority: $0.0, weight: $0.1, port: $0.2, target: $0.3) },
      txt: txt, address: address)
  }
}
