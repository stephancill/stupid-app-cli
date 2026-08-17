import Foundation
import Testing

@testable import DeviceKit

struct CoreDeviceUSBLauncherTests {
  @Test("CDTunnel handshake frames round-trip with the shared codec")
  func handshakeFraming() throws {
    let request = try CoreDeviceTLSConnection.frame([
      "mtu": 16_000,
      "type": "clientHandshakeRequest",
    ])
    #expect(request.prefix(8) == Data("CDTunnel".utf8))
    let bodyLength = (Int(request[8]) << 8) | Int(request[9])
    #expect(bodyLength > 0)
    #expect(request.count == 10 + bodyLength)
    let object = try JSONSerialization.jsonObject(with: request.dropFirst(10)) as? [String: Any]
    #expect(object?["type"] as? String == "clientHandshakeRequest")
    #expect(object?["mtu"] as? Int == 16_000)
  }

  @Test("invalid CDTunnel response header is rejected")
  func invalidResponseHeader() {
    var response = Data("not-cdtunnel!".utf8)
    response.append(contentsOf: [0, 0])
    #expect(throws: CoreDeviceUSBLauncher.Error.self) {
      _ = try CoreDeviceUSBLauncher.handshakeResponse(from: response)
    }
  }

  @Test("truncated CDTunnel response body is rejected")
  func truncatedResponseBody() {
    var header = Data("CDTunnel".utf8)
    header.append(contentsOf: [0, 100])
    header.append(Data(repeating: 0x20, count: 10))
    #expect(throws: CoreDeviceUSBLauncher.Error.self) {
      _ = try CoreDeviceUSBLauncher.handshakeResponse(from: header)
    }
  }
}

struct NativeCoreDeviceRunnerTests {
  @Test("parsePID accepts a valid helper status line")
  func parsePID() {
    #expect(
      NativeCoreDeviceRunner.parsePID(
        #"{"status":"ok","operation":"launch-usb","pid":1234}"#) == 1234
    )
  }

  @Test("parsePID rejects missing or invalid pid fields")
  func parsePIDRejects() {
    #expect(NativeCoreDeviceRunner.parsePID(#"{"status":"ok","operation":"launch-usb"}"#) == nil)
    #expect(NativeCoreDeviceRunner.parsePID(#"{"status":"error"}"#) == nil)
    #expect(NativeCoreDeviceRunner.parsePID("not json") == nil)
    #expect(NativeCoreDeviceRunner.parsePID(#"{"status":"ok","pid":0}"#) == nil)
  }

  @Test("device identifier is redacted from helper diagnostics")
  func redaction() {
    let udid = "00008100-PRIVATE-DEVICE-ID"
    #expect(
      NativeCoreDeviceRunner.redact(detail: "launch failed for \(udid)", udid: udid)
        == "launch failed for <device-udid>"
    )
  }
}
