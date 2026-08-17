import Foundation

public protocol USBDeviceDiscovering: Sendable {
  /// Returns the UDIDs of USB-connected devices visible to the transport.
  func usbDeviceUDIDs() throws -> [String]
}
