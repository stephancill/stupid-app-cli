import Foundation

/// Installs and launches an app on a physical device. The transport is injectable so
/// the USB (Gate 3) and wireless (Gate 4) proofs can share one orchestration boundary
/// while swapping the underlying device tooling.
public protocol DeviceInstaller: Sendable {
    /// Installs an IPA on the target device (or the single connected device).
    func install(ipa: URL, udid: String?) throws
    /// Launches an installed app by bundle identifier.
    func launch(bundleID: String, udid: String?) throws
    /// Returns the UDIDs of USB-connected devices visible to the transport.
    func usbDeviceUDIDs() throws -> [String]
}
