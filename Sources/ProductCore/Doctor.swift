import ASCKit
import BuildCore
import DeviceKit
import Foundation
import ProjectCore
import SDKCore
import SigningKit

public enum Doctor {
  public enum Status: String, Equatable, Sendable {
    case pass
    case warning
    case failure
  }

  public struct Result: Equatable, Sendable {
    public var name: String
    public var status: Status
    public var detail: String

    public init(name: String, status: Status, detail: String) {
      self.name = name
      self.status = status
      self.detail = detail
    }
  }

  public struct Input: Sendable {
    public var projectRoot: URL
    public var credentialHome: URL
    public var sdkID: String
    public var swiftPath: String
    public var sudoPath: String?
    /// Overrides automatic host-SDK-mode detection (used by tests on hosts where the
    /// real mode would make assertions environment-dependent).
    public var hostSDKMode: HostSDKMode?

    public init(
      projectRoot: URL,
      credentialHome: URL,
      sdkID: String = "stupid-app-ios",
      swiftPath: String = "swift",
      sudoPath: String? = nil,
      hostSDKMode: HostSDKMode? = nil
    ) {
      self.projectRoot = projectRoot
      self.credentialHome = credentialHome
      self.sdkID = sdkID
      self.swiftPath = swiftPath
      self.sudoPath = sudoPath
      self.hostSDKMode = hostSDKMode
    }
  }

  public static func run(input: Input) -> [Result] {
    var results: [Result] = []

    let mode = input.hostSDKMode ?? HostSDKMode.detect()
    let toolchainSwift: String
    switch mode {
    case .xcodeInPlace(let installation):
      toolchainSwift =
        input.swiftPath == "swift" ? installation.toolchainSwiftURL.path : input.swiftPath
    case .importedBundle:
      toolchainSwift = input.swiftPath
    }

    results.append(hostSDKModeResult(mode: mode, swiftPath: toolchainSwift))

    results.append(
      check(name: "Swift toolchain") {
        let host = try HostInfo.detect(swiftPath: toolchainSwift)
        let version =
          try HostInfo.compilerVersion(swiftPath: toolchainSwift) ?? "Swift version unavailable"
        return "\(version); host \(host.triple)"
      })

    results.append(
      check(name: "iOS Swift SDK") {
        try checkSDK(input: input, mode: mode, swiftPath: toolchainSwift)
      })

    if case .xcodeInPlace = mode,
      SDKVersion.isInstalled(sdkID: input.sdkID, swiftPath: toolchainSwift)
    {
      results.append(
        Result(
          name: "Imported SDK bundle",
          status: .warning,
          detail:
            "Xcode SDK in place is active, so the imported '\(input.sdkID)' bundle is unused and consumes space. Remove it with `swift sdk remove \(input.sdkID)`."
        )
      )
    }

    results.append(
      check(name: "Native signing trust") {
        try AppleSigningTrust.validateQualifiedChain()
        return "Pinned Apple WWDR G3 and Apple Inc. root certificates are valid."
      })

    results.append(
      check(name: "Native CoreDevice TLS") {
        try CoreDeviceTLSConnection.validateOpenSSL()
        return "OpenSSL 3.x provides TLS 1.2 and the required CoreDevice PSK cipher."
      })

    let pairingDirectory = input.credentialHome.appendingPathComponent("pairing", isDirectory: true)
    results.append(
      check(name: "CoreDevice helper") {
        let runner = NativeCoreDeviceRunner(
          sudoPath: input.sudoPath,
          pairingDirectory: pairingDirectory
        )
        try runner.validateEnvironment(requirePrivileges: false)
        return "The native CoreDevice helper is available; privileged operations use sudo."
      })

    results.append(credentialResult(home: input.credentialHome))
    results.append(identityResult(home: input.credentialHome, kind: "development"))
    results.append(identityResult(home: input.credentialHome, kind: "distribution"))
    results.append(pairingResult(directory: pairingDirectory))
    results.append(projectResult(root: input.projectRoot))

    #if os(Linux)
      results.append(
        FileManager.default.fileExists(atPath: "/dev/net/tun")
          ? Result(
            name: "CoreDevice tunnel device",
            status: .pass,
            detail:
              "/dev/net/tun exists; privileged access is still required for device operations."
          )
          : Result(
            name: "CoreDevice tunnel device",
            status: .failure,
            detail:
              "/dev/net/tun is missing. Load the TUN device before pairing or running on a device."
          ))

      results.append(
        FileManager.default.fileExists(atPath: "/var/run/usbmuxd")
          ? Result(name: "usbmuxd socket", status: .pass, detail: "/var/run/usbmuxd exists.")
          : Result(
            name: "usbmuxd socket",
            status: .warning,
            detail:
              "No /var/run/usbmuxd socket exists. USB pairing and installation are unavailable."
          ))
    #elseif os(macOS)
      results.append(usbmuxdSocketResult())
      results.append(utunResult(sudoPath: input.sudoPath))
    #endif

    return results
  }

  private static func check(name: String, operation: () throws -> String) -> Result {
    do {
      return Result(name: name, status: .pass, detail: try operation())
    } catch {
      return Result(name: name, status: .failure, detail: String(describing: error))
    }
  }

  private static func hostSDKModeResult(mode: HostSDKMode, swiftPath: String) -> Result {
    switch mode {
    case .xcodeInPlace(let installation):
      return Result(
        name: "Host SDK mode",
        status: .pass,
        detail:
          "Xcode SDK in place: Xcode \(installation.version) (\(installation.build)) at \(installation.appURL.path); iPhoneOS SDK \(installation.iphoneosSDKVersion); toolchain swift at \(installation.toolchainSwiftURL.path)."
      )
    case .importedBundle:
      return Result(
        name: "Host SDK mode",
        status: .pass,
        detail:
          "Imported artifact bundle: no usable Xcode detected; builds use the imported bundle with host Swift at \(swiftPath)."
      )
    }
  }

  private static func checkSDK(input: Input, mode: HostSDKMode, swiftPath: String) throws -> String
  {
    switch mode {
    case .xcodeInPlace(let installation):
      let fm = FileManager.default
      guard fm.fileExists(atPath: installation.iphoneOSSDKURL.path),
        fm.isExecutableFile(atPath: installation.toolchainSwiftURL.path)
      else {
        throw CompatibilityError.incompleteXcodeInPlace(installation.appURL.path)
      }
      return
        "Xcode SDK in place provides iPhoneOS SDK \(installation.iphoneosSDKVersion) without an artifact bundle."
    case .importedBundle:
      let host = try HostInfo.detect(swiftPath: swiftPath)
      let manifest = try SDKVersion.installedManifest(
        sdkID: input.sdkID,
        swiftPath: swiftPath
      )
      guard manifest.hostTriple == host.triple else {
        throw CompatibilityError.host(expected: manifest.hostTriple, actual: host.triple)
      }
      guard
        manifest.swiftCompiler.major == host.swiftMajor,
        manifest.swiftCompiler.minor == host.swiftMinor
      else {
        throw CompatibilityError.swift(
          expected: "\(manifest.swiftCompiler.major).\(manifest.swiftCompiler.minor)",
          actual: "\(host.swiftMajor).\(host.swiftMinor)"
        )
      }
      return "\(input.sdkID) is compatible (iPhoneOS SDK \(manifest.iphoneosSDKVersion))."
    }
  }

  private static func credentialResult(home: URL) -> Result {
    let store = CredentialStore(home: home)
    let required = [
      CredentialStore.Secret.ascKey.rawValue,
      CredentialStore.Secret.ascKeyID.rawValue,
      CredentialStore.Secret.ascIssuerID.rawValue,
      CredentialStore.Secret.developerTeamID.rawValue,
    ]
    guard required.allSatisfy(store.exists) else {
      return Result(
        name: "App Store Connect credentials",
        status: .warning,
        detail:
          "Credentials are incomplete. Run `stupid-app credentials add` before signing or release."
      )
    }
    return permissionResult(
      name: "App Store Connect credentials",
      directory: home,
      files: required.map(store.fileURL(forSecret:)),
      success: "Credential files are present with owner-only permissions."
    )
  }

  private static func identityResult(home: URL, kind: String) -> Result {
    let store = CredentialStore(home: home)
    let names: [String]
    switch kind {
    case "development":
      names = [
        IdentityManager.Secret.developmentKey.rawValue,
        IdentityManager.Secret.developmentCert.rawValue,
        IdentityManager.Secret.developmentCertID.rawValue,
      ]
    default:
      names = [
        IdentityManager.Secret.distributionKey.rawValue,
        IdentityManager.Secret.distributionCert.rawValue,
        IdentityManager.Secret.distributionCertID.rawValue,
      ]
    }
    guard names.allSatisfy(store.exists) else {
      return Result(
        name: "\(kind.capitalized) signing identity",
        status: .warning,
        detail:
          "No complete \(kind) identity is stored. Run `stupid-app signing setup --kind \(kind)`."
      )
    }
    return permissionResult(
      name: "\(kind.capitalized) signing identity",
      directory: home,
      files: names.map(store.fileURL(forSecret:)),
      success: "The \(kind) identity files are present with owner-only permissions."
    )
  }

  private static func pairingResult(directory: URL) -> Result {
    guard FileManager.default.fileExists(atPath: directory.path) else {
      return Result(
        name: "CoreDevice pairing records",
        status: .warning,
        detail:
          "No pairing directory exists. Run `stupid-app device pair --usb` before network deployment."
      )
    }
    let files =
      ((try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      )) ?? []).filter { $0.pathExtension == "plist" }
    guard !files.isEmpty else {
      return Result(
        name: "CoreDevice pairing records",
        status: .warning,
        detail: "The pairing directory contains no records. Run `stupid-app device pair --usb`."
      )
    }
    return permissionResult(
      name: "CoreDevice pairing records",
      directory: directory,
      files: files,
      success: "Pairing records are present with owner-only permissions."
    )
  }

  private static func projectResult(root: URL) -> Result {
    let configURL = root.appendingPathComponent("stupid-app.yml")
    guard FileManager.default.fileExists(atPath: configURL.path) else {
      return Result(
        name: "Project configuration",
        status: .warning,
        detail: "No stupid-app.yml exists at \(root.path); project-specific checks were skipped."
      )
    }
    return check(name: "Project configuration") {
      let config = try AppConfig.decode(Data(contentsOf: configURL))
      try config.validate(projectRoot: root.path)
      let requiredPaths =
        ["Package.swift", config.infoPath]
        + [config.entitlementsPath, config.iconPath].compactMap { $0 }
        + (config.resources ?? [])
        + extensionPaths(from: config)
      let missing = requiredPaths.filter {
        !FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
      }
      guard missing.isEmpty else {
        throw CompatibilityError.missingProjectFiles(missing)
      }
      return "stupid-app.yml is valid for \(config.product) (\(config.bundleID))."
    }
  }

  /// Collects the project file paths contributed by configured extensions
  /// (info plist, entitlements, resources, and App Intents metadata).
  private static func extensionPaths(from config: AppConfig) -> [String] {
    guard let extensions = config.extensions else { return [] }
    var paths: [String] = []
    for ext in extensions {
      paths.append(ext.infoPath)
      paths += [ext.entitlementsPath].compactMap { $0 }
      paths += ext.resources ?? []
      paths += [ext.appIntentsMetadata].compactMap { $0 }
    }
    return paths
  }

  private enum CompatibilityError: Swift.Error, CustomStringConvertible {
    case host(expected: String, actual: String)
    case swift(expected: String, actual: String)
    case incompleteXcodeInPlace(String)
    case missingProjectFiles([String])

    var description: String {
      switch self {
      case .host(let expected, let actual):
        return
          "The installed SDK requires host \(expected), but this host is \(actual). Import a matching SDK export."
      case .swift(let expected, let actual):
        return
          "The installed SDK requires Swift \(expected), but this host has Swift \(actual). Install the compatible Swift toolchain."
      case .incompleteXcodeInPlace(let app):
        return
          "Xcode SDK in place is active but Xcode at \(app) is missing its iPhoneOS SDK or toolchain swift."
      case .missingProjectFiles(let paths):
        return
          "The project configuration references missing files: \(paths.joined(separator: ", "))."
      }
    }
  }

  private static func permissionResult(
    name: String,
    directory: URL,
    files: [URL],
    success: String
  ) -> Result {
    guard permissions(at: directory) == 0o700 else {
      return Result(
        name: name,
        status: .failure,
        detail: "Credential directory \(directory.path) must have mode 0700."
      )
    }
    for file in files where permissions(at: file) != 0o600 {
      return Result(
        name: name,
        status: .failure,
        detail: "Secret file \(file.lastPathComponent) must have mode 0600."
      )
    }
    return Result(name: name, status: .pass, detail: success)
  }

  private static func permissions(at url: URL) -> Int? {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let value = attributes[.posixPermissions] as? NSNumber
    else {
      return nil
    }
    return value.intValue & 0o777
  }

  #if os(macOS)
    private static func usbmuxdSocketResult() -> Result {
      FileManager.default.fileExists(atPath: "/var/run/usbmuxd")
        ? Result(name: "usbmuxd socket", status: .pass, detail: "/var/run/usbmuxd exists.")
        : Result(
          name: "usbmuxd socket",
          status: .warning,
          detail:
            "No /var/run/usbmuxd socket exists. Start usbmuxd or connect the device; USB pairing and installation are unavailable."
        )
    }

    private static func utunResult(sudoPath: String?) -> Result {
      // macOS creates utun interfaces through the privileged CoreDevice helper
      // (a kernel-control socket requires root). The reachable precondition is
      // that the interface can be created, which needs the explicit --sudo
      // boundary; report the boundary requirement so a missing route or
      // privilege does not surface as a silent timeout.
      let privilegeNote: String
      if let sudoPath {
        privilegeNote =
          FileManager.default.isExecutableFile(atPath: sudoPath)
          ? "sudo at \(sudoPath) is available."
          : "Configured sudo at \(sudoPath) is not executable."
      } else {
        #if os(macOS)
          privilegeNote = "Pass --sudo to enable privileged utun operations."
        #else
          privilegeNote = ""
        #endif
      }
      return Result(
        name: "CoreDevice tunnel device",
        status: .pass,
        detail:
          "macOS utun interfaces are created by the privileged helper. \(privilegeNote)"
      )
    }
  #endif
}
