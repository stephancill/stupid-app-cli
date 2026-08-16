import ArgumentParser
import Foundation
import SDKCore

/// `stupid-app sdk`: manage the imported iOS Swift SDK.
struct SDKCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sdk",
        abstract: "Manage the imported iOS Swift SDK.",
        subcommands: [SDKExportCommand.self, SDKImportCommand.self]
    )
}