import Foundation
import Testing
@testable import DeviceKit

/// Unit tests for the pymobiledevice3 USB installer wrapper. No device or tooling is
/// required; only binary-missing and output-parsing behavior is exercised.
struct PyMobileDevice3InstallerTests {
    @Test("missing installer binary fails loudly")
    func missingBinary() {
        let installer = PyMobileDevice3Installer(executablePath: "/nonexistent/pymobiledevice3")
        #expect(throws: PyMobileDevice3Installer.Error.self) {
            try installer.usbDeviceUDIDs()
        }
    }

    @Test("parses simple UDID list output")
    func parsesUDIDList() {
        let output = "00008100-0000000000000000\n\n00008101-0000000000000000\n"
        let udids = PyMobileDevice3Installer.parseUDIDList(output)
        #expect(udids == ["00008100-0000000000000000", "00008101-0000000000000000"])
    }

    @Test("empty output yields no devices")
    func emptyOutput() {
        #expect(PyMobileDevice3Installer.parseUDIDList("").isEmpty)
    }
}
