import Foundation
import Testing

@testable import DeviceKit

struct NativeUSBInstallerTests {
  @Test("encodes AFC headers and split write payloads")
  func afcPacketEncoding() throws {
    var payload = Data()
    AFCClient.appendLittleEndian(42, to: &payload)
    payload.append(Data("body".utf8))
    let packet = try AFCClient.encode(
      operation: .write,
      packetNumber: 7,
      payload: payload,
      headerLength: 48
    )
    let header = try AFCClient.decodeHeader(Data(packet.prefix(AFCClient.headerSize)))
    #expect(header.entireLength == packet.count)
    #expect(header.headerLength == 48)
    #expect(header.packetNumber == 7)
    #expect(header.operation == .write)
    #expect(AFCClient.littleEndianUInt64(packet, at: AFCClient.headerSize) == 42)
  }

  @Test("rejects malformed and oversized AFC headers")
  func malformedAFCHeaders() throws {
    #expect(throws: NativeUSBInstaller.Error.self) {
      try AFCClient.decodeHeader(Data(repeating: 0, count: AFCClient.headerSize))
    }
    #expect(throws: NativeUSBInstaller.Error.self) {
      try AFCClient.encode(
        operation: .write,
        packetNumber: 0,
        payload: Data(),
        headerLength: AFCClient.headerSize + 1
      )
    }
  }

  @Test("native USB install can run against an explicitly enabled physical fixture")
  func liveInstall() throws {
    let environment = ProcessInfo.processInfo.environment
    guard
      let ipa = environment["NATIVE_USB_INSTALL_IPA"],
      environment["NATIVE_USB_INSTALL"] == "1"
    else {
      return
    }
    let usbmuxAddress = environment["NATIVE_USBMUX_ADDRESS"]
    let udid =
      try environment["NATIVE_USB_INSTALL_UDID"] ?? #require(
        USBMuxClient(address: usbmuxAddress).usbDeviceUDIDs().only
      )
    let bundleID: String
    if let supplied = environment["NATIVE_USB_INSTALL_BUNDLE_ID"] {
      bundleID = supplied
    } else {
      let infoPath = try #require(environment["NATIVE_USB_INSTALL_INFO_PLIST"])
      let data = try Data(contentsOf: URL(fileURLWithPath: infoPath))
      let info = try #require(
        PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
      )
      bundleID = try #require(info["CFBundleIdentifier"] as? String)
    }
    try NativeUSBInstaller(
      usbmuxAddress: usbmuxAddress,
      timeoutSeconds: Double(environment["NATIVE_USB_INSTALL_TIMEOUT"] ?? "300") ?? 300,
      progress: { print($0) }
    ).install(
      ipa: URL(fileURLWithPath: ipa),
      bundleID: bundleID,
      udid: udid
    )
  }
}

extension Collection {
  fileprivate var only: Element? {
    count == 1 ? first : nil
  }
}
