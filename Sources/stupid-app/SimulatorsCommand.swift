import ArgumentParser
import BuildCore
import Foundation
import SDKCore

/// `stupid-app simulators`: list the available simulator runtimes and devices. This is
/// an Xcode-present-only feature; simulators cannot exist without Xcode.
struct SimulatorsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "simulators",
    abstract: "List the available simulator runtimes and devices."
  )

  mutating func run() async throws {
    guard case .xcodeInPlace = HostSDKMode.detect() else {
      throw BuildError.simulatorRequiresXcode
    }

    let runtimes = try Simctl.listRuntimes()
    let devices = try Simctl.listDevices()

    print("Available simulator runtimes:")
    for runtime in runtimes {
      print("  \(runtime.name) (\(runtime.identifier))")
    }

    print("Available simulator devices:")
    for device in devices {
      print("  \(device.name) (\(device.udid)) \(device.state)")
    }

    if runtimes.isEmpty {
      print(
        "No simulator runtimes are installed. Install one with `xcodebuild -downloadPlatform iOS`."
      )
    }
  }
}