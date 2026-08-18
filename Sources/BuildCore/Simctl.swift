import Foundation
import SDKCore

/// Thin wrapper over `xcrun simctl` for the Xcode-present simulator run loop. This is
/// the single scoped product use of Apple runtime tooling: simulators cannot exist
/// without Xcode, and simulator `.app` output is never a device or release artifact.
public enum Simctl {
  public struct Device: Sendable, Equatable {
    public var name: String
    public var udid: String
    public var state: String
    public var runtimeIdentifier: String

    public init(name: String, udid: String, state: String, runtimeIdentifier: String) {
      self.name = name
      self.udid = udid
      self.state = state
      self.runtimeIdentifier = runtimeIdentifier
    }
  }

  public struct Runtime: Sendable, Equatable {
    public var name: String
    public var identifier: String

    public init(name: String, identifier: String) {
      self.name = name
      self.identifier = identifier
    }
  }

  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case xcrunUnavailable
    case commandFailed(String)
    case unparseableOutput(String)

    public var description: String {
      switch self {
      case .xcrunUnavailable:
        return
          "`xcrun` is unavailable. Simulator support requires an Xcode installation with a simulator runtime."
      case let .commandFailed(detail):
        return "simctl failed. \(detail)"
      case let .unparseableOutput(output):
        return "Could not parse `simctl` output: \(output)"
      }
    }
  }

  public static let xcrunPath: String = {
    let candidates = [HostInfo.resolveExecutable("xcrun"), "/usr/bin/xcrun"]
    return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
      ?? "/usr/bin/xcrun"
  }()

  /// Lists the simulator devices for installed runtimes.
  public static func listDevices() throws -> [Device] {
    try parseDevices(try run(["list", "devices", "--json"]))
  }

  /// Parses `simctl list devices --json` output. Exposed for hermetic tests.
  static func parseDevices(_ output: String) throws -> [Device] {
    struct Root: Decodable {
      var devices: [String: [RawDevice]]
    }
    struct RawDevice: Decodable {
      var name: String
      var udid: String
      var state: String
    }
    guard let data = output.data(using: .utf8),
      let root = try? JSONDecoder().decode(Root.self, from: data)
    else {
      throw Error.unparseableOutput(output)
    }
    return
      root.devices
      .sorted { $0.key < $1.key }
      .flatMap { runtime, entries in
        entries.map { Device(name: $0.name, udid: $0.udid, state: $0.state, runtimeIdentifier: runtime) }
      }
  }

  /// Lists the installed simulator runtimes.
  public static func listRuntimes() throws -> [Runtime] {
    try parseRuntimes(try run(["list", "runtimes", "--json"]))
  }

  /// Parses `simctl list runtimes --json` output. Exposed for hermetic tests.
  static func parseRuntimes(_ output: String) throws -> [Runtime] {
    struct Root: Decodable {
      var runtimes: [RawRuntime]
    }
    struct RawRuntime: Decodable {
      var name: String
      var identifier: String
    }
    guard let data = output.data(using: .utf8),
      let root = try? JSONDecoder().decode(Root.self, from: data)
    else {
      throw Error.unparseableOutput(output)
    }
    return root.runtimes
      .sorted { $0.name < $1.name }
      .map { Runtime(name: $0.name, identifier: $0.identifier) }
  }

  /// Boots a device; succeeds when it is already booted.
  public static func boot(udid: String) throws {
    _ = try run(["boot", udid])
  }

  /// Waits until the device finishes booting.
  public static func bootStatus(udid: String) throws {
    _ = try run(["bootstatus", udid, "-b"])
  }

  /// Installs an assembled `.app` bundle (ad-hoc or otherwise signed).
  public static func install(udid: String, appURL: URL) throws {
    _ = try run(["install", udid, appURL.path])
  }

  /// Launches an installed app by bundle identifier and returns its process id.
  public static func launch(udid: String, bundleID: String) throws -> Int {
    let output = try run(["launch", udid, bundleID])
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let components = trimmed.split(separator: " ").map(String.init)
    guard
      let last = components.last,
      let pid = Int(last)
    else {
      throw Error.commandFailed("launch returned unexpected output: \(output)")
    }
    return pid
  }

  private static func run(_ arguments: [String]) throws -> String {
    guard FileManager.default.isExecutableFile(atPath: xcrunPath) else {
      throw Error.xcrunUnavailable
    }
    // `simctl` listing output routinely exceeds the default 20 KB bound; keep enough
    // for the full JSON listings while still bounding memory.
    let result = try ProcessRunner.run(
      executable: xcrunPath,
      arguments: ["simctl"] + arguments,
      configuration: .init(maxOutputBytes: 2_000_000)
    )
    guard result.succeeded else {
      let detail = result.stderr.isEmpty ? result.stdout : result.stderr
      throw Error.commandFailed("`simctl \(arguments.joined(separator: " "))`: \(detail)")
    }
    return result.stdout
  }
}