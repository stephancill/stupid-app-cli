import ArgumentParser
import Foundation
import ASCKit

/// `stupid-app devices`: list and register App Store Connect devices.
struct DevicesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "List and register App Store Connect devices.",
        subcommands: [DevicesListCommand.self, DevicesAddCommand.self],
        defaultSubcommand: DevicesListCommand.self
    )
}

/// `stupid-app devices list`: list registered devices.
struct DevicesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List registered devices."
    )

    @Option(name: .customLong("home"), help: "Credential store directory.")
    var home: String?

    mutating func run() async throws {
        let context = try ASCContext.resolve(home: home, purpose: "devices list")
        let devices = try context.operations().listDevices()

        if devices.isEmpty {
            print("No devices registered.")
            return
        }
        let nameWidth = max(devices.map { $0.name?.count ?? 0 }.max() ?? 0, 4)
        let udidWidth = max(devices.map { $0.udid?.count ?? 0 }.max() ?? 0, 4)
        let statusWidth = max(devices.map { $0.status?.count ?? 0 }.max() ?? 0, 6)
        print(String(format: "%-\(nameWidth)s  %-\(udidWidth)s  %-\(statusWidth)s", "Name", "UDID", "Status"))
        for device in devices {
            print(String(
                format: "%-\(nameWidth)s  %-\(udidWidth)s  %-\(statusWidth)s",
                device.name ?? "-", device.udid ?? "-", device.status ?? "-"
            ))
        }
    }
}

/// `stupid-app devices add`: register a physical device.
struct DevicesAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Register a physical device by UDID."
    )

    @Option(name: .customLong("udid"), help: "Physical device UDID.")
    var udid: String

    @Option(name: .customLong("name"), help: "Device display name.")
    var name: String = "iPhone"

    @Option(name: .customLong("home"), help: "Credential store directory.")
    var home: String?

    mutating func run() async throws {
        let context = try ASCContext.resolve(home: home, purpose: "devices add")
        let device = try context.operations().getOrRegisterDevice(udid: udid, name: name)
        print("Device \(device.id) (\(device.udid ?? udid))")
    }
}
