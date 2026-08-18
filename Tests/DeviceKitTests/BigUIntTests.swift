import Foundation
import Testing

@testable import DeviceKit

struct BigUIntTests {
  @Test("BigUInt hex round-trip")
  func hexRoundTrip() {
    let value = BigUInt(hex: "deadbeef")
    #expect(value.hex == "deadbeef")
    let big = BigUInt(hex: "0123456789abcdef0123456789abcdef")
    #expect(big.hex == "0123456789abcdef0123456789abcdef")
  }

  @Test("BigUInt addition carries across limbs")
  func addition() {
    let a = BigUInt(hex: "ffffffffffffffff")
    let b = BigUInt(1)
    #expect((a + b).hex == "010000000000000000")
  }

  @Test("BigUInt subtraction borrows across limbs")
  func subtraction() {
    let a = BigUInt(hex: "10000000000000000")
    let b = BigUInt(1)
    #expect((a - b).hex == "ffffffffffffffff")
  }

  @Test("BigUInt multiplication")
  func multiplication() {
    let a = BigUInt(0xFFFF_FFFF_FFFF_FFFF)
    #expect((a * a).hex == "fffffffffffffffe0000000000000001")
  }

  @Test("BigUInt division and remainder")
  func division() {
    let a = BigUInt(hex: "10000000000000000")
    let b = BigUInt(hex: "ffffffffffffffff")
    let (quotient, remainder) = a.quotientAndRemainder(dividingBy: b)
    #expect(quotient == BigUInt(1))
    #expect(remainder == BigUInt(1))
    let (q2, r2) = a.quotientAndRemainder(dividingBy: BigUInt(2))
    #expect(q2 == BigUInt(hex: "8000000000000000"))
    #expect(r2 == BigUInt(0))
  }

  @Test("BigUInt modular exponentiation matches small known values")
  func modPow() {
    #expect(BigUInt(3).power(BigUInt(5), mod: BigUInt(17)) == BigUInt(5))
    // 5^17 mod (3072-bit prime) from the reference SRP vector.
    let expected = BigUInt(hex: "b1a2bc2ec5")
    let actual = BigUInt(5).power(BigUInt(17), mod: SRPClient.prime)
    #expect(actual == expected)
  }
}
