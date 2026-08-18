import Crypto
import Foundation

/// A minimal SRP client session for the 3072-bit/SHA-512 group used by
/// CoreDevice remote pairing, mirroring `srptools` exactly so the Pair-Setup
/// exchange matches the device.
struct SRPClient {
  static let prime = BigUInt(hex: Self.primeHex)
  static let generator = BigUInt(5)

  // RFC 5054 group 16 (3072-bit) N.
  static let primeHex =
    "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF"

  let username: String
  let password: String
  let privateA: BigUInt

  var clientPublic: BigUInt {
    SRPClient.generator.power(privateA, mod: SRPClient.prime)
  }

  init(username: String, password: String, privateA: BigUInt) {
    self.username = username
    self.password = password
    self.privateA = privateA
  }

  /// A value fed into a hash. Integers are encoded with their minimal
  /// big-endian byte representation, matching srptools' `conv`.
  enum Input {
    case int(BigUInt)
    case data(Data)
    case string(String)

    var bytes: Data {
      switch self {
      case .int(let value):
        return value.data
      case .data(let value):
        return value
      case .string(let value):
        return Data(value.utf8)
      }
    }
  }

  static func sha512(_ data: Data) -> Data {
    Data(SHA512.hash(data: data))
  }

  /// `hash(args, joiner)` returning the raw digest bytes.
  static func digest(_ args: [Input], joiner: Data = Data()) -> Data {
    var input = Data()
    for (index, arg) in args.enumerated() {
      if index > 0 {
        input.append(joiner)
      }
      input.append(arg.bytes)
    }
    return sha512(input)
  }

  /// `hash(args, joiner)` returning the digest as an integer.
  static func hashInt(_ args: [Input], joiner: Data = Data()) -> BigUInt {
    BigUInt(data: digest(args, joiner: joiner))
  }

  struct Session {
    var salt: Data
    var sessionKey: Data
    var keyProof: Data
    var keyProofHash: Data
  }

  /// Runs the full client exchange given the server salt and public value,
  /// mirroring `SRPClientSession.process`.
  func process(salt: Data, serverPublic: BigUInt) throws -> Session {
    let n = SRPClient.prime
    let g = SRPClient.generator
    let paddedLength = n.data.count

    // k = H(N | PAD(g))
    let k = SRPClient.hashInt([
      .data(n.data),
      .data(g.paddedData(to: paddedLength)),
    ])

    // x = H(salt | H(I | ":" | P))
    let inner = SRPClient.digest(
      [.string(username), .string(password)], joiner: Data(":".utf8))
    let x = SRPClient.hashInt([.data(salt), .data(inner)])

    // v = g^x mod N
    let verifier = g.power(x, mod: n)

    // A = g^a mod N
    let aPublic = clientPublic

    // u = H(PAD(A) | PAD(B))
    let u = SRPClient.hashInt([
      .data(aPublic.paddedData(to: paddedLength)),
      .data(serverPublic.paddedData(to: paddedLength)),
    ])

    // S = (B - k*v) ^ (a + u*x) mod N, tolerating a negative base.
    let kv = k * verifier
    let negative = kv > serverPublic
    let base = negative ? kv - serverPublic : serverPublic - kv
    let exponent = privateA + (u * x)
    var premaster = base.power(exponent, mod: n)
    if negative && exponent.isOdd {
      premaster = premaster.isZero ? BigUInt(0) : n - premaster
    }

    // K = H(S)
    let keyBytes = SRPClient.sha512(premaster.data)

    // hN = H(N), hG = H(g), hU = H(U)
    let hN = SRPClient.sha512(n.data)
    let hG = SRPClient.sha512(g.data)
    let hU = SRPClient.digest([.string(username)])

    // M = H(H(N) XOR H(g) | H(U) | s | A | B | K)
    let hNXorHG = BigUInt(data: Data(zip(hN, hG).map { $0 ^ $1 }))
    let proofM = SRPClient.digest([
      .int(hNXorHG),
      .int(BigUInt(data: hU)),
      .data(salt),
      .int(aPublic),
      .int(serverPublic),
      .data(keyBytes),
    ])

    // M2 = H(A | M | K)
    let proofM2 = SRPClient.digest([.int(aPublic), .data(proofM), .data(keyBytes)])

    return Session(salt: salt, sessionKey: keyBytes, keyProof: proofM, keyProofHash: proofM2)
  }
}
