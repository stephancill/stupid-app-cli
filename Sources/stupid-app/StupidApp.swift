import ArgumentParser
import Foundation

@main
struct StupidApp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stupid-app",
        abstract: "Build, sign, deploy, and release iOS apps without Xcode.",
        subcommands: [SDKCommand.self]
    )
}