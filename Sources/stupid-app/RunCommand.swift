import ArgumentParser
import Foundation
import ASCKit
import BuildCore
import DeviceKit
import ProjectCore
import SDKCore
import SigningKit

/// `stupid-app run`: build, sign, install, and launch the app on a physical device.
/// Gate 3 implements USB install; the wireless (`--network`) path is Gate 4.
struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Build, sign, install, and launch the app on a device."
    )

    @Flag(name: .customLong("usb"), help: "Install over USB (Gate 3).")
    var usb = false

    @Flag(name: .customLong("network"), help: "Install over the network (Gate 4, not yet implemented).")
    var network = false

    @Option(name: .customLong("udid"), help: "Target device UDID (auto-detected when omitted with one USB device).")
    var udid: String?

    @Option(name: .customLong("sdk-id"), help: "Imported Swift SDK identifier (default stupid-app-ios).")
    var sdkID: String = "stupid-app-ios"

    @Option(name: .customLong("swift"), help: "Path to the host `swift` executable.")
    var swiftPath: String = "swift"

    @Option(name: .customLong("rcodesign"), help: "Path to the pinned rcodesign binary.")
    var rcodesignPath: String = "rcodesign"

    @Option(name: .customLong("pymobiledevice3"), help: "Path to the pymobiledevice3 CLI used for USB install/launch.")
    var pymobilePath: String = "pymobiledevice3"

    @Option(name: .customLong("usbmux"), help: "usbmuxd address (unix socket or HOST:PORT) passed to pymobiledevice3.")
    var usbmuxAddress: String?

    @Option(name: .customLong("home"), help: "Credential store directory.")
    var home: String?

    mutating func run() async throws {
        guard usb, !network else {
            throw RunError.unsupportedTransport
        }

        let context = try ASCContext.resolve(home: home, purpose: "run")

        let configURL = URL(fileURLWithPath: "stupid-app.yml")
        guard let data = try? Data(contentsOf: configURL) else {
            throw ProjectError.unreadableConfig(configURL.path)
        }
        let config = try AppConfig.decode(data)
        let projectRoot = URL(fileURLWithPath: ".")

        // 1. Build the unsigned app (debug configuration).
        let planner = Planner(projectRoot: projectRoot, config: config, swiftPath: swiftPath)
        let plan = try planner.makePlan()
        guard SDKVersion.isInstalled(sdkID: sdkID, swiftPath: swiftPath) else {
            throw SDKVersion.Error.sdkNotInstalled(sdkID)
        }
        let packer = Packer(
            projectRoot: projectRoot,
            plan: plan,
            config: config,
            swiftPath: swiftPath,
            sdkID: sdkID,
            buildConfiguration: .debug
        )
        let unsignedApp = try packer.pack()
        print("Assembled unsigned \(unsignedApp.path)")

        // 2. Load the development identity and device development profile.
        let identity = try IdentityManager(store: context.credentialStore).loadDevelopment()
        guard let teamID = identity.teamID else {
            throw RunError.identityMissingTeam
        }
        let profileURL = try locateProfile(home: context.homeURL, bundleID: config.bundleID)

        // 3. Sign once with development entitlements and package the IPA.
        let ipaDir = projectRoot
            .appendingPathComponent(".build/arm64-apple-ios/debug", isDirectory: true)
        let output = try SigningPipeline.signAndPackage(input: .init(
            unsignedApp: unsignedApp,
            identity: identity,
            teamID: teamID,
            profileURL: profileURL,
            sourceEntitlementsURL: projectRoot.appendingPathComponent(config.entitlementsPath ?? "App.entitlements"),
            configuration: .development,
            bundleID: config.bundleID,
            rcodesignPath: rcodesignPath,
            product: config.product,
            ipaOutputDirectory: ipaDir
        ))
        print("Signed \(output.appBundle.path)")
        print("Packaged \(output.ipaURL.path)")
        print("IPA SHA-256: \(try SHA256.file(at: output.ipaURL))")

        // 4. Determine the target device.
        let installer = PyMobileDevice3Installer(
            executablePath: pymobilePath,
            usbmuxAddress: usbmuxAddress
        )
        let targetUDID = try resolveTargetUDID(installer: installer)

        // 5. Install and launch over USB.
        print("Installing on \(targetUDID ?? "<auto>") over USB...")
        try installer.install(ipa: output.ipaURL, udid: targetUDID)
        print("Installed.")
        try installer.launch(bundleID: config.bundleID, udid: targetUDID)
        print("Launched \(config.bundleID).")
    }

    private func resolveTargetUDID(installer: PyMobileDevice3Installer) throws -> String? {
        if let udid {
            return udid
        }
        let devices = try installer.usbDeviceUDIDs()
        guard devices.count == 1 else {
            throw RunError.deviceSelection(devices.count)
        }
        print("Using USB device \(devices[0])")
        return devices[0]
    }

    private func locateProfile(home: URL, bundleID: String) throws -> URL {
        let candidates = [
            home.appendingPathComponent("profiles/\(bundleID) Development.mobileprovision"),
            home.appendingPathComponent("profiles/\(bundleID).mobileprovision"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        throw RunError.profileMissing(bundleID)
    }
}

enum RunError: Error, CustomStringConvertible {
    case unsupportedTransport
    case identityMissingTeam
    case profileMissing(String)
    case deviceSelection(Int)

    var description: String {
        switch self {
        case .unsupportedTransport:
            return "`run` supports only --usb in Gate 3. The --network path lands in Gate 4."
        case .identityMissingTeam:
            return "The stored development identity has no team ID. Re-run `stupid-app signing setup --kind development`."
        case let .profileMissing(bundleID):
            return "No development profile found for '\(bundleID)'. Run `stupid-app signing setup --kind development --bundle-id <id> --udid <udid>` first."
        case let .deviceSelection(count):
            return "Expected exactly one USB-connected device, found \(count). Pass --udid to select a device."
        }
    }
}
