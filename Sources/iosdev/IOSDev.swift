import ArgumentParser
import Foundation

@main
struct IOSDev: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iosdev",
        abstract: "Build, sign, deploy, and release iOS apps without Xcode.",
        subcommands: [SDKCommand.self]
    )
}
