import Foundation
import SDKCore

#if canImport(Glibc)
  import Glibc
#endif

/// The Linux simulator run loop: x86Sim (https://github.com/x86sim/x86sim) runs Apple's
/// iOS simulator runtime on x86-64 Linux. Devices and boots come from stupid simulator's
/// `stupidsim-linux` (which sets x86Sim up from its runtime store); install and launch go
/// through x86Sim's own simctl-like command line. Like `Simctl`, simulator `.app` output
/// here is never a device or release artifact.
public enum X86Sim {
  public struct Device: Sendable, Equatable {
    /// The x86Sim device name (`agent` for `device-a64-agent`).
    public var name: String
    public var udid: String
    /// The device directory (`X86SIM_DEVICE`).
    public var directory: URL
    public var booted: Bool
  }

  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case launcherMissing(String)
    case noDevices(String)
    case deviceNotFound(String, [String])
    case deviceSelection([String])
    case bootUnavailable(String)
    case commandFailed(String)

    public var description: String {
      switch self {
      case .launcherMissing(let path):
        return
          "x86Sim is not installed: no launcher at \(path). Set up a simulator with stupid simulator's `stupidsim-linux setup` (see its cloud-setup.sh), or point STUPIDSIM_X86SIM at x86Sim's extracted AppRun."
      case .noDevices(let root):
        return
          "No x86Sim devices under \(root). Create one with `stupidsim-linux setup --no-boot`."
      case .deviceNotFound(let wanted, let available):
        return
          "No x86Sim device '\(wanted)'. Available: \(available.joined(separator: ", ")). Pass a device name or UDID with --udid."
      case .deviceSelection(let available):
        return
          "Several x86Sim devices exist (\(available.joined(separator: ", "))) and none is booted. Pass one with --udid."
      case .bootUnavailable(let name):
        return
          "Device '\(name)' is not booted and `stupidsim-linux` is not on PATH to boot it. Boot it with `stupidsim-linux boot --device \(name)`."
      case .commandFailed(let detail):
        return "x86Sim failed. \(detail)"
      }
    }
  }

  static var environment: [String: String] { ProcessInfo.processInfo.environment }

  static var dataHome: URL {
    if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
      return URL(fileURLWithPath: xdg, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".local/share", isDirectory: true)
  }

  /// x86Sim's extracted AppRun, found the way stupidsim finds it.
  public static var launcherPath: String {
    environment["STUPIDSIM_X86SIM"]
      ?? dataHome.appendingPathComponent("stupidsim/x86sim/AppRun").path
  }

  /// `$X86SIM_DATA/var`, where x86Sim keeps `device-a64[-<name>]` directories.
  static var devicesRoot: URL {
    let data =
      environment["X86SIM_DATA"].map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? dataHome.appendingPathComponent("x86sim", isDirectory: true)
    return data.appendingPathComponent("var", isDirectory: true)
  }

  public static func listDevices() throws -> [Device] {
    let root = devicesRoot
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: root.path))?
      .filter { $0 == "device-a64" || $0.hasPrefix("device-a64-") }
      .sorted() ?? []
    return names.compactMap { entry in
      let directory = root.appendingPathComponent(entry, isDirectory: true)
      guard let udid = simEnvironment(directory)["SIMULATOR_UDID"] else { return nil }
      let name = entry == "device-a64" ? "default" : String(entry.dropFirst("device-a64-".count))
      return Device(
        name: name, udid: udid, directory: directory, booted: isBooted(directory))
    }
  }

  /// Picks the device named or identified by `wanted`, else the only booted one, else the
  /// only one.
  public static func selectDevice(_ wanted: String?) throws -> Device {
    let devices = try listDevices()
    guard !devices.isEmpty else { throw Error.noDevices(devicesRoot.path) }
    if let wanted {
      guard let match = devices.first(where: { $0.name == wanted || $0.udid == wanted }) else {
        throw Error.deviceNotFound(wanted, devices.map(\.name))
      }
      return match
    }
    let booted = devices.filter(\.booted)
    if booted.count == 1 { return booted[0] }
    if devices.count == 1 { return devices[0] }
    throw Error.deviceSelection(devices.map(\.name))
  }

  /// Boots the device through `stupidsim-linux`, which waits for the home screen.
  public static func boot(_ device: Device) throws {
    guard let tool = which("stupidsim-linux") else { throw Error.bootUnavailable(device.name) }
    let result = try ProcessRunner.run(
      executable: tool, arguments: ["boot", "--device", device.name],
      configuration: .init(maxOutputBytes: 200_000, timeoutSeconds: 1200))
    guard result.succeeded else {
      throw Error.commandFailed("`stupidsim-linux boot --device \(device.name)`: \(result.failureOutput)")
    }
  }

  public static func install(_ device: Device, appURL: URL) throws {
    _ = try run(device, ["install", appURL.standardizedFileURL.path])
  }

  public struct Launch: Sendable {
    public var pid: Int
    /// Where the app's stdout and stderr go (Linux paths), for the agent to read.
    public var stdout: URL
    public var stderr: URL
  }

  /// Launches an installed app by bundle identifier, replacing a running instance so an
  /// edit always runs fresh, with its stdout and stderr in files under the device's
  /// `data/tmp/stupid-app/`. x86Sim prints `<bundle id>: <pid>`, as simctl does.
  public static func launch(_ device: Device, bundleID: String, arguments: [String] = []) throws
    -> Launch
  {
    let relative = "tmp/stupid-app"
    let directory = device.directory.appendingPathComponent("data/\(relative)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stdout = directory.appendingPathComponent("\(bundleID).stdout")
    let stderr = directory.appendingPathComponent("\(bundleID).stderr")
    for file in [stdout, stderr] {
      FileManager.default.createFile(atPath: file.path, contents: nil)
    }
    let output = try run(
      device,
      [
        "launch", "--terminate-running-process",
        "--stdout=\(relative)/\(bundleID).stdout", "--stderr=\(relative)/\(bundleID).stderr",
        bundleID,
      ] + arguments)
    guard
      let line = output.split(separator: "\n").last(where: { $0.hasPrefix("\(bundleID):") }),
      let pid = Int(line.split(separator: " ").last ?? "")
    else {
      throw Error.commandFailed("launch returned unexpected output: \(output)")
    }
    return Launch(pid: pid, stdout: stdout, stderr: stderr)
  }

  /// Whether the app has a running process.
  public static func isRunning(_ device: Device, bundleID: String) -> Bool {
    (try? run(device, ["pidof", bundleID])) != nil
  }

  /// The application in front, as stupid simulator's `stupidsim ui-tree` names it (its
  /// display name), or nil when stupidsim is not installed or the tree cannot be read.
  public static func frontmostApplication(_ device: Device) -> String? {
    guard let stupidsim = which("stupidsim") else { return nil }
    var environment = environment
    environment["X86SIM_DEVICE"] = device.directory.path
    guard
      let result = try? ProcessRunner.run(
        executable: stupidsim, arguments: ["ui-tree", device.udid], environment: environment,
        configuration: .init(maxOutputBytes: 2_000_000, timeoutSeconds: 30)),
      result.succeeded,
      let line = result.stdout.split(separator: "\n").first(where: { $0.hasPrefix("Application \"") }),
      let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close
    else { return nil }
    return String(line[line.index(after: open)..<close])
  }

  public static var hasStupidsim: Bool { which("stupidsim") != nil }

  private static func run(_ device: Device, _ arguments: [String]) throws -> String {
    let launcher = launcherPath
    guard FileManager.default.isExecutableFile(atPath: launcher) else {
      throw Error.launcherMissing(launcher)
    }
    var environment = environment
    environment["X86SIM_DEVICE"] = device.directory.path
    environment["SHELL"] = "/bin/bash"
    let result = try ProcessRunner.run(
      executable: launcher, arguments: ["x86sim"] + arguments, environment: environment,
      configuration: .init(maxOutputBytes: 2_000_000, timeoutSeconds: 600))
    guard result.succeeded else {
      throw Error.commandFailed("`x86sim \(arguments.joined(separator: " "))`: \(result.failureOutput)")
    }
    return result.stdout
  }

  static func simEnvironment(_ directory: URL) -> [String: String] {
    guard
      let text = try? String(
        contentsOf: directory.appendingPathComponent("sim.env"), encoding: .utf8)
    else { return [:] }
    var values: [String: String] = [:]
    for line in text.split(separator: "\n") {
      guard let equals = line.firstIndex(of: "=") else { continue }
      values[String(line[..<equals])] = String(line[line.index(after: equals)...])
    }
    return values
  }

  /// A device is booted when its input socket (simhid) accepts a connection, the test
  /// stupidsim uses: the socket file outlives a shutdown.
  static func isBooted(_ directory: URL) -> Bool {
    #if canImport(Glibc)
      let path = directory.appendingPathComponent("data/simhid.sock").resolvingSymlinksInPath().path
      let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
      guard fd >= 0 else { return false }
      defer { close(fd) }
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      let bytes = Array(path.utf8)
      guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
      withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        for (index, byte) in bytes.enumerated() { buffer[index] = byte }
      }
      let size = socklen_t(MemoryLayout<sockaddr_un>.size)
      return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) == 0 }
      }
    #else
      return false
    #endif
  }

  static func which(_ name: String) -> String? {
    let path = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
    for directory in path.split(separator: ":") {
      let candidate = "\(directory)/\(name)"
      if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
  }
}
