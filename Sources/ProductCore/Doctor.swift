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
    public var pythonPath: String
    public var pymobiledevice3Path: String
    public var sudoPath: String?
    public var coreDeviceHelperPath: String?

    public init(
      projectRoot: URL,
      credentialHome: URL,
      sdkID: String = "stupid-app-ios",
      swiftPath: String = "swift",
      pythonPath: String = "python3",
      pymobiledevice3Path: String = "pymobiledevice3",
      sudoPath: String? = nil,
      coreDeviceHelperPath: String? = nil
    ) {
      self.projectRoot = projectRoot
      self.credentialHome = credentialHome
      self.sdkID = sdkID
      self.swiftPath = swiftPath
      self.pythonPath = pythonPath
      self.pymobiledevice3Path = pymobiledevice3Path
      self.sudoPath = sudoPath
      self.coreDeviceHelperPath = coreDeviceHelperPath
    }
  }

  public static func run(input: Input) -> [Result] {
    var results: [Result] = []

    results.append(
      check(name: "Swift toolchain") {
        let host = try HostInfo.detect(swiftPath: input.swiftPath)
        let version =
          try HostInfo.compilerVersion(swiftPath: input.swiftPath) ?? "Swift version unavailable"
        return "\(version); host \(host.triple)"
      })

    results.append(
      check(name: "iOS Swift SDK") {
        let host = try HostInfo.detect(swiftPath: input.swiftPath)
        let manifest = try SDKVersion.installedManifest(
          sdkID: input.sdkID,
          swiftPath: input.swiftPath
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
      })

    results.append(
      check(name: "Native signing trust") {
        try AppleSigningTrust.validateQualifiedChain()
        return "Pinned Apple WWDR G3 and Apple Inc. root certificates are valid."
      })

    let pairingDirectory = input.credentialHome.appendingPathComponent("pairing", isDirectory: true)
    let validationDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("stupid-app-doctor-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: validationDirectory) }
    results.append(
      check(name: "CoreDevice environment") {
        let runner = CoreDeviceRunner(
          pythonPath: input.pythonPath,
          sudoPath: input.sudoPath,
          helperPath: input.coreDeviceHelperPath,
          pairingDirectory: validationDirectory
        )
        try runner.validateEnvironment(requirePrivileges: false)
        return "Python 3.13, pymobiledevice3 8.2.1, and construct-typing 0.7.0 are available."
      })

    results.append(
      check(name: "USB installer") {
        let path = HostInfo.resolveExecutable(input.pymobiledevice3Path)
        guard FileManager.default.isExecutableFile(atPath: path) else {
          throw PyMobileDevice3Installer.Error.binaryMissing(path)
        }
        return "pymobiledevice3 is executable at \(path)."
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
      let missing = requiredPaths.filter {
        !FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
      }
      guard missing.isEmpty else {
        throw CompatibilityError.missingProjectFiles(missing)
      }
      return "stupid-app.yml is valid for \(config.product) (\(config.bundleID))."
    }
  }

  private enum CompatibilityError: Swift.Error, CustomStringConvertible {
    case host(expected: String, actual: String)
    case swift(expected: String, actual: String)
    case missingProjectFiles([String])

    var description: String {
      switch self {
      case .host(let expected, let actual):
        return
          "The installed SDK requires host \(expected), but this host is \(actual). Import a matching SDK export."
      case .swift(let expected, let actual):
        return
          "The installed SDK requires Swift \(expected), but this host has Swift \(actual). Install the compatible Swift toolchain."
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
}
