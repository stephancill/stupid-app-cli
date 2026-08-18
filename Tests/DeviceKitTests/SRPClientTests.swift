import Foundation
import Testing

@testable import DeviceKit

struct SRPClientTests {
  /// Deterministic vector generated with the pinned srptools against the same
  /// 3072-bit group, a fixed private `a`, salt, and server public value.
  @Test("SRP session matches the srptools reference vector")
  func referenceVector() throws {
    let a = BigUInt(hex: String(repeating: "0123456789abcdef", count: 16))
    let salt = Data(
      hexString:
        "f0c075ab4742252a98561814df3f401c27cb6ea868051fb20b845c2cfbbbd2ca6"
        + "1b4266a7a70adfbbd75c6ae108cfce93f5008c75666546abf98d6491076e08e")
    let serverPublic = BigUInt(hex: "b1a2bc2ec5")

    let client = SRPClient(username: "Pair-Setup", password: "000000", privateA: a)
    let session = try client.process(salt: salt, serverPublic: serverPublic)

    #expect(
      client.clientPublic.hex
        == "54dc3e82d8f738aadcedb072b2cf8214eea1d22ecad020d66c1c2d70cd0bf19"
        + "f4dae8067c07408a6949114807824e8e05aaf531cd2f64e973526689040ccac0"
        + "e89a25ef0faeab2f6d66f304b860728b44a517cd7d388622fc64790d78c046bc"
        + "0a2b1221e40d8fa7b149cf2a428c5e041927e686bde2ec5792acf39f674fee59"
        + "f4cb3f1a352a5f7083c79d1cf66bc257a951cb2363b1289bcef29f9ceb2c1a12"
        + "77af8b013e11152d99e13965ab3327d87bd33d32e9e59f5394c9e1e607abbf3"
        + "99d6474e5b0cdd32b5b8e78b6d3d3bd0c67212265409f495bcbd3ab94506c0ab"
        + "bc6b0fcaad6d207f4e4b5137a0ab7bffe03523be0826da0ecedbc0d4b7eb25de"
        + "8490b1b8a1796f00bb52b6c5f913d1d5c66559a02c48b4bc01527c7acc20bbb2"
        + "1bc159b5299a51893574c2fd2bed37e2d451142ec8654eb0f2b80816f28ecd7a"
        + "8ff4c668a2c2f6157a8fb6c3e04c5346fe4906993fa832f15c152dceb9da0efd"
        + "eb48f867b0d9a8185c9ffbb082a5e1ff69d1aae5c5e2ceecfc4d28f8e22b48d1ef")
    #expect(
      hex(session.sessionKey)
        == "08f17b83fec30b3a899dd990aa5dcda391d3fb063afae9e8db8edb6565ba8fa4"
        + "bd51e8dd8c0f14145b32dbed974cb20f1cd9fffde50c673e76440c4259170980")
    #expect(
      hex(session.keyProof)
        == "5b784e9c90e00b6beb0594398f3ae7df5b32fb1355135655bda9d057ade21728"
        + "a2439a38c2b020adec678697ce79aa93e790b8f3c2fc8cb7680642ccb1880c1d")
    #expect(
      hex(session.keyProofHash)
        == "c358c5ff622626f5c4e313531ecce18def7940a88af3e577d7e57c29f5e532a7"
        + "3aab69031bb8c296c2522b3ff5a0d2f9476aa60a08d6ff0678a67d88572cf608")
  }

  private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }
}
