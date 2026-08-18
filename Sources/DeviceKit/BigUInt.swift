import Foundation

/// An arbitrary-precision unsigned integer used by the SRP-3072 remote pairing
/// exchange. Limbs are stored least-significant-first (limb 0 is the low
/// 64-bit word). This is a deliberately narrow implementation sized for the
/// 3072-bit SRP group: it needs add, subtract, multiply, bit shifts, byte/hex
/// conversion, and modular exponentiation via Montgomery multiplication.
struct BigUInt: Equatable, Sendable {
  static let limbBits = 64
  static let limbMask: UInt64 = ~0

  var limbs: [UInt64]

  init() {
    limbs = []
  }

  init(limbs: [UInt64]) {
    var value = limbs
    while value.last == 0, value.count > 1 {
      value.removeLast()
    }
    if value.isEmpty {
      value = [0]
    }
    self.limbs = value
  }

  init(_ value: UInt64) {
    self.init(limbs: value == 0 ? [0] : [value])
  }

  /// Interprets a big-endian byte buffer as an unsigned integer.
  init(data: Data) {
    var words: [UInt64] = []
    var buffer: [UInt8] = Array(data)
    if buffer.isEmpty {
      buffer = [0]
    }
    // Left-pad to a multiple of 8 bytes.
    let remainder = buffer.count % 8
    if remainder != 0 {
      buffer.insert(contentsOf: repeatElement(0, count: 8 - remainder), at: 0)
    }
    for index in stride(from: 0, to: buffer.count, by: 8) {
      var word: UInt64 = 0
      for byte in buffer[index..<(index + 8)] {
        word = (word << 8) | UInt64(byte)
      }
      words.append(word)
    }
    words.reverse()  // limb 0 is the least-significant word
    self.init(limbs: words)
  }

  init(hex: String) {
    var normalized = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
    if normalized.count % 2 != 0 {
      normalized = "0" + normalized
    }
    guard !normalized.isEmpty else {
      self.init(0)
      return
    }
    var bytes = Data()
    var cursor = normalized.startIndex
    while cursor < normalized.endIndex {
      let next = normalized.index(cursor, offsetBy: 2)
      if let byte = UInt8(normalized[cursor..<next], radix: 16) {
        bytes.append(byte)
      } else {
        bytes.append(0)
      }
      cursor = next
    }
    self.init(data: bytes)
  }

  // MARK: - Conversion

  /// Minimal big-endian byte representation (empty for zero).
  var data: Data {
    if isZero {
      return Data()
    }
    var words = limbs
    while words.last == 0, words.count > 1 {
      words.removeLast()
    }
    var bytes = Data()
    for word in words.reversed() {
      var value = word
      var wordBytes = [UInt8]()
      for _ in 0..<8 {
        wordBytes.append(UInt8(value & 0xFF))
        value >>= 8
      }
      bytes.append(contentsOf: wordBytes.reversed())
    }
    while let first = bytes.first, first == 0 {
      bytes.removeFirst()
    }
    return bytes
  }

  /// Minimal lowercase hex string with even length, matching Python's
  /// `'%x' % value` padded to an even number of digits.
  var hex: String {
    let bytes = data
    if bytes.isEmpty {
      return "00"
    }
    var output = ""
    for byte in bytes {
      output += String(format: "%02x", byte)
    }
    return output
  }

  /// The value right-padded with zero bytes to exactly `count` bytes
  /// (left-padded when the value is smaller, matching srptools' `pad`).
  func paddedData(to count: Int) -> Data {
    let bytes = data
    guard bytes.count < count else { return bytes }
    return Data(repeating: 0, count: count - bytes.count) + bytes
  }

  // MARK: - Predicates

  var isZero: Bool {
    limbs.allSatisfy { $0 == 0 }
  }

  var isOdd: Bool {
    !isZero && (limbs[0] & 1) == 1
  }

  var bitWidth: Int {
    guard let top = limbs.last, top != 0 else { return 0 }
    return (limbs.count - 1) * 64 + (64 - top.leadingZeroBitCount)
  }

  // MARK: - Comparison

  static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
    if lhs.limbs.count != rhs.limbs.count {
      return lhs.limbs.count < rhs.limbs.count
    }
    for index in stride(from: lhs.limbs.count - 1, through: 0, by: -1) {
      if lhs.limbs[index] != rhs.limbs[index] {
        return lhs.limbs[index] < rhs.limbs[index]
      }
    }
    return false
  }

  static func > (lhs: BigUInt, rhs: BigUInt) -> Bool {
    rhs < lhs
  }

  static func <= (lhs: BigUInt, rhs: BigUInt) -> Bool {
    !(rhs < lhs)
  }

  static func >= (lhs: BigUInt, rhs: BigUInt) -> Bool {
    !(lhs < rhs)
  }

  // MARK: - Addition and subtraction

  static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
    let count = max(lhs.limbs.count, rhs.limbs.count)
    var result: [UInt64] = []
    result.reserveCapacity(count + 1)
    var carry: UInt64 = 0
    for index in 0..<count {
      let left = index < lhs.limbs.count ? lhs.limbs[index] : 0
      let right = index < rhs.limbs.count ? rhs.limbs[index] : 0
      let (sum, overflow1) = left.addingReportingOverflow(right)
      let (sum2, overflow2) = sum.addingReportingOverflow(carry)
      result.append(sum2)
      carry = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
    }
    result.append(carry)
    return BigUInt(limbs: result)
  }

  /// Requires `lhs >= rhs`.
  static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
    precondition(lhs >= rhs, "BigUInt subtraction requires lhs >= rhs")
    let count = max(lhs.limbs.count, rhs.limbs.count)
    var result: [UInt64] = []
    result.reserveCapacity(count)
    var borrow: UInt64 = 0
    for index in 0..<count {
      let left = index < lhs.limbs.count ? lhs.limbs[index] : 0
      let right = index < rhs.limbs.count ? rhs.limbs[index] : 0
      let (partial, overflow1) = left.subtractingReportingOverflow(right)
      let (value, overflow2) = partial.subtractingReportingOverflow(borrow)
      result.append(value)
      borrow = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
    }
    return BigUInt(limbs: result)
  }

  // MARK: - Multiplication

  /// Schoolbook long multiplication.
  static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
    if lhs.isZero || rhs.isZero {
      return BigUInt(0)
    }
    var result = [UInt64](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
    for (i, left) in lhs.limbs.enumerated() {
      var carry: UInt64 = 0
      for (j, right) in rhs.limbs.enumerated() {
        let (high, low) = multipliedFullWidth(left, right)
        let (sum1, overflow1) = result[i + j].addingReportingOverflow(low)
        let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
        result[i + j] = sum2
        let carryAdd = (overflow1 ? UInt64(1) : 0) + (overflow2 ? UInt64(1) : 0)
        carry = high &+ carryAdd
      }
      let (finalSum, finalOverflow) = result[i + rhs.limbs.count].addingReportingOverflow(carry)
      result[i + rhs.limbs.count] = finalSum
      _ = finalOverflow
    }
    return BigUInt(limbs: result)
  }

  /// Splits a 128-bit product into its high and low 64-bit words.
  private static func multipliedFullWidth(_ lhs: UInt64, _ rhs: UInt64) -> (
    high: UInt64, low: UInt64
  ) {
    lhs.multipliedFullWidth(by: rhs)
  }

  // MARK: - Shifts

  func shiftedLeft(byBits shift: Int) -> BigUInt {
    guard shift > 0, !isZero else { return self }
    let wordShift = shift / 64
    let bitShift = shift % 64
    var result = [UInt64](repeating: 0, count: limbs.count + wordShift + 1)
    var overflow: UInt64 = 0
    for index in 0..<limbs.count {
      let current = limbs[index]
      result[index + wordShift] = overflow | (current << bitShift)
      overflow = bitShift == 0 ? 0 : (current >> (64 - bitShift))
    }
    result[limbs.count + wordShift] = overflow
    return BigUInt(limbs: result)
  }

  func bit(at index: Int) -> UInt64 {
    let word = index / 64
    let shift = index % 64
    guard word < limbs.count else { return 0 }
    return (limbs[word] >> shift) & UInt64(1)
  }

  // MARK: - Division

  /// Binary long division returning (quotient, remainder).
  func quotientAndRemainder(dividingBy divisor: BigUInt) -> (quotient: BigUInt, remainder: BigUInt)
  {
    precondition(!divisor.isZero, "division by zero")
    if self < divisor {
      return (BigUInt(0), self)
    }
    var quotient = BigUInt(0)
    var remainder = BigUInt(0)
    let width = bitWidth
    if width == 0 {
      return (BigUInt(0), BigUInt(0))
    }
    for index in stride(from: width - 1, through: 0, by: -1) {
      remainder = remainder.shiftedLeft(byBits: 1)
      remainder.limbs[0] |= bit(at: index)
      if remainder >= divisor {
        remainder = remainder - divisor
        quotient = quotient | BigUInt(1).shiftedLeft(byBits: index)
      }
    }
    return (quotient, remainder)
  }

  static func % (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
    lhs.quotientAndRemainder(dividingBy: rhs).remainder
  }

  // MARK: - Bitwise OR (used for quotient construction)

  static func | (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
    let count = max(lhs.limbs.count, rhs.limbs.count)
    var result: [UInt64] = []
    for index in 0..<count {
      let left = index < lhs.limbs.count ? lhs.limbs[index] : 0
      let right = index < rhs.limbs.count ? rhs.limbs[index] : 0
      result.append(left | right)
    }
    return BigUInt(limbs: result)
  }

  // MARK: - Modular exponentiation (Montgomery)

  /// Computes `base^exponent mod modulus` for an odd `modulus` using
  /// Montgomery multiplication.
  func power(_ exponent: BigUInt, mod modulus: BigUInt) -> BigUInt {
    precondition(!modulus.isZero, "modulus must be nonzero")
    if modulus == BigUInt(1) {
      return BigUInt(0)
    }
    let words = modulus.limbs.count
    let rShift = words * 64
    let r = BigUInt(1).shiftedLeft(byBits: rShift)
    let r2 = (r % modulus) * (r % modulus) % modulus
    let inv = modulus.montgomeryInverse()

    func redc(_ value: BigUInt) -> BigUInt {
      // value may span up to 2n words; leave one spare word for the carry.
      var words2 = value.limbs
      if words2.count < words * 2 + 1 {
        words2.append(contentsOf: [UInt64](repeating: 0, count: words * 2 + 1 - words2.count))
      }
      for index in 0..<words {
        let m = words2[index].multipliedFullWidth(by: inv).low
        // add m * modulus << (64 * index)
        var carry: UInt64 = 0
        for j in 0..<words {
          let (high, low) = m.multipliedFullWidth(by: modulus.limbs[j])
          let (sum1, overflow1) = words2[index + j].addingReportingOverflow(low)
          let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
          words2[index + j] = sum2
          carry = high &+ (overflow1 ? UInt64(1) : 0) &+ (overflow2 ? UInt64(1) : 0)
        }
        // propagate carry beyond the modulus length
        var k = index + words
        while carry != 0 {
          if k < words2.count {
            let (sum, overflow) = words2[k].addingReportingOverflow(carry)
            words2[k] = sum
            carry = overflow ? 1 : 0
          } else {
            words2.append(carry)
            carry = 0
          }
          k += 1
        }
      }
      var result = BigUInt(limbs: Array(words2[words...]))
      while result >= modulus {
        result = result - modulus
      }
      return result
    }

    func toMont(_ value: BigUInt) -> BigUInt {
      redc(value * r2)
    }

    func fromMont(_ value: BigUInt) -> BigUInt {
      redc(value)
    }

    var montBase = toMont(self % modulus)
    var result = toMont(BigUInt(1))
    var exponentBits = exponent
    while !exponentBits.isZero {
      if exponentBits.isOdd {
        result = redc(result * montBase)
      }
      exponentBits = exponentBits.shiftedRight(byBits: 1)
      if !exponentBits.isZero {
        montBase = redc(montBase * montBase)
      }
    }
    return fromMont(result)
  }

  private func shiftedRight(byBits shift: Int) -> BigUInt {
    guard shift > 0, !isZero else { return self }
    let wordShift = shift / 64
    let bitShift = shift % 64
    guard wordShift < limbs.count else { return BigUInt(0) }
    var result = [UInt64](repeating: 0, count: limbs.count - wordShift)
    var incoming: UInt64 = 0
    for index in stride(from: limbs.count - 1, through: wordShift, by: -1) {
      let current = limbs[index]
      result[index - wordShift] = (current >> bitShift) | incoming
      incoming = bitShift == 0 ? 0 : (current << (64 - bitShift))
    }
    return BigUInt(limbs: result)
  }

  /// Returns `-modulus^-1 mod 2^64`, the Montgomery inverse for `redc`.
  private func montgomeryInverse() -> UInt64 {
    // Newton iteration in the 64-bit ring.
    var inverse = modulusLowUInt64()
    for _ in 0..<5 {
      inverse = inverse &* (2 &- modulusLowUInt64() &* inverse)
    }
    return 0 &- inverse
  }

  private func modulusLowUInt64() -> UInt64 {
    limbs.first ?? 0
  }
}
