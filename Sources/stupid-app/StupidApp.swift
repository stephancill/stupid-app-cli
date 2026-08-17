import ArgumentParser
import Foundation

@main
struct StupidApp: AsyncParsableCommand {
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
      ReleaseCommand.self,
    ]
  )
}
