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

  @Flag(name: .customLong("json"), help: "Print machine-readable JSON instead of a human summary.")
  var json = false

  mutating func run() async throws {
    guard case .xcodeInPlace = HostSDKMode.detect() else {
      throw BuildError.simulatorRequiresXcode
    }

    let runtimes = try Simctl.listRuntimes()
    let devices = try Simctl.listDevices()

    if json {
      let payload = SimulatorsJSON(
        runtimes: runtimes.map { RuntimeJSON(name: $0.name, identifier: $0.identifier) },
        devices: devices.map {
          DeviceJSON(name: $0.name, udid: $0.udid, state: $0.state, runtimeIdentifier: $0.runtimeIdentifier)
        }
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      print(String(data: try encoder.encode(payload), encoding: .utf8) ?? "{}")
      return
    }

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

  private struct SimulatorsJSON: Encodable {
    var runtimes: [RuntimeJSON]
    var devices: [DeviceJSON]
  }

  private struct RuntimeJSON: Encodable {
    var name: String
    var identifier: String
  }

  private struct DeviceJSON: Encodable {
    var name: String
    var udid: String
    var state: String
    var runtimeIdentifier: String
  }
}