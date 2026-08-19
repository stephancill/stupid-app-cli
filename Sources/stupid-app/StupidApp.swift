import ArgumentParser
import Foundation
import SDKCore

@main
struct StupidApp: AsyncParsableCommand {
  /// The product version reported by `stupid-app --version`.
  static let productVersion = "0.0.3"

  static let configuration = CommandConfiguration(
    commandName: "stupid-app",
    abstract: "Build, sign, deploy, and release iOS apps without Xcode.",
    subcommands: [
      DoctorCommand.self,
      NewCommand.self,
      SDKCommand.self,
      BuildCommand.self,
      CredentialsCommand.self,
      SigningCommand.self,
      DevicesCommand.self,
      DeviceCommand.self,
      RunCommand.self,
      SimulatorsCommand.self,
      ReleaseCommand.self,
      CoreDeviceHelperCommand.self,
    ]
  )

  @Flag(name: .shortAndLong, help: "Print version information and exit.")
  var version = false

  mutating func run() async throws {
    if version {
      let toolchain = (try? HostInfo.compilerVersion()) ?? "Swift compiler unavailable"
      print(Self.versionInformation(compilerVersion: toolchain))
      return
    }
    throw CleanExit.helpRequest()
  }

  /// The `--version` output: the product version plus the host Swift compiler line.
  static func versionInformation(compilerVersion: String) -> String {
    return "stupid-app \(productVersion)\n\(compilerVersion)"
  }
}
