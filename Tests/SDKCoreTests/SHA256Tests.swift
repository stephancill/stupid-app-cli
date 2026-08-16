import Crypto
import Foundation
import Testing
@testable import SDKCore

/// Tests the SDK `SHA256` wrapper against published test vectors.
///
/// The expected digests below are the canonical NIST FIPS 180-4 / RFC 6234 SHA-256
/// example vectors. Passing them exercises the exact hashing path used for the SDK
/// manifest, so an incorrect link or platform backend would fail here first.
struct SHA256Tests {
    @Test("empty message")
    func emptyMessage() {
        let expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        #expect(SHA256.hex(data: Data()) == expected)
    }

    @Test("abc")
    func abc() {
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(SHA256.hex(data: Data("abc".utf8)) == expected)
    }

    @Test("two block message")
    func twoBlock() {
        let input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        let expected = "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        #expect(SHA256.hex(data: Data(input.utf8)) == expected)
    }

    @Test("one million a")
    func oneMillionA() {
        let input = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        let expected = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        #expect(SHA256.hex(data: input) == expected)
    }

    @Test("file digest equals in-memory digest")
    func fileDigest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "iosdev-sha256-tests-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("payload.bin")
        let payload = Data((0..<2_000_000).map { UInt8($0 % 251) })
        try payload.write(to: url)

        #expect(try SHA256.file(at: url) == SHA256.hex(data: payload))
    }
}
