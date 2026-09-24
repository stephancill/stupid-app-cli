import Foundation
import ProjectCore
import Testing

@testable import BuildCore

/// The synthesized `Info.plist` device-family and orientation keys for each declared
/// `deviceFamily`, for both the app and a bundled extension.
struct InfoPlistDeviceFamilyTests {
  private static let sourceInfoPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleDisplayName</key>
        <string>Fixture</string>
    </dict>
    </plist>
    """

  private func makePlanner() throws -> (Planner, URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("planner-device-family-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(Self.sourceInfoPlist.utf8).write(to: root.appendingPathComponent("Info.plist"))
    let config = AppConfig(
      version: 1,
      product: "Fixture",
      bundleID: "net.example.fixture",
      deploymentTarget: "17.0",
      infoPath: "Info.plist"
    )
    return (Planner(projectRoot: root, config: config), root)
  }

  private func synthesize(deviceFamily: DeviceFamily, isExtension: Bool) throws -> [String: Sendable]
  {
    let (planner, root) = try makePlanner()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    return try planner.synthesizeInfoPlist(
      product: "Fixture",
      bundleID: isExtension ? "net.example.fixture.widget" : "net.example.fixture",
      deploymentTarget: "17.0",
      platform: .device,
      isExtension: isExtension,
      infoPath: "Info.plist",
      deviceFamily: deviceFamily
    )
  }

  @Test("iPhone-only app declares UIDeviceFamily [1] and no iPad orientations")
  func iphoneOnlyApp() throws {
    let info = try synthesize(deviceFamily: .iphone, isExtension: false)
    #expect(info["UIDeviceFamily"] as? [Int] == [1])
    #expect(info["UISupportedInterfaceOrientations"] as? [String] == ["UIInterfaceOrientationPortrait"])
    #expect(info["UISupportedInterfaceOrientations~ipad"] == nil)
    #expect(info["LSRequiresIPhoneOS"] as? Bool == true)
  }

  @Test("universal app declares UIDeviceFamily [1, 2] and all iPad orientations")
  func universalApp() throws {
    let info = try synthesize(deviceFamily: .universal, isExtension: false)
    #expect(info["UIDeviceFamily"] as? [Int] == [1, 2])
    #expect(
      info["UISupportedInterfaceOrientations~ipad"] as? [String] == [
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationPortraitUpsideDown",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
      ])
  }

  @Test("iPad-only app declares UIDeviceFamily [2] and all iPad orientations")
  func ipadOnlyApp() throws {
    let info = try synthesize(deviceFamily: .ipad, isExtension: false)
    #expect(info["UIDeviceFamily"] as? [Int] == [2])
    #expect((info["UISupportedInterfaceOrientations~ipad"] as? [String])?.count == 4)
  }

  @Test("a bundled extension declares the app's device family and no app-only keys")
  func extensionMatchesAppFamily() throws {
    let info = try synthesize(deviceFamily: .iphone, isExtension: true)
    #expect(info["UIDeviceFamily"] as? [Int] == [1])
    #expect(info["LSRequiresIPhoneOS"] == nil)
    #expect(info["UISupportedInterfaceOrientations"] == nil)
    #expect(info["UISupportedInterfaceOrientations~ipad"] == nil)
    #expect(info["UILaunchScreen"] == nil)
  }
}
