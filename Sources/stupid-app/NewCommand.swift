import ArgumentParser
import Foundation
import ProjectCore

/// `stupid-app new`: scaffolds a SwiftPM/SwiftUI application project in the supported
/// project model. Never invokes Xcode.
struct NewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new",
        abstract: "Create a new SwiftPM/SwiftUI iOS application project."
    )

    @Argument(help: "Project and product name, e.g. AcceptanceApp.")
    var name: String

    @Option(name: .customLong("bundle-id"), help: "Exact bundle identifier, e.g. net.example.acceptance-app.")
    var bundleID: String?

    @Option(name: .customLong("deployment-target"), help: "Minimum iOS version, e.g. 17.0.")
    var deploymentTarget: String = "17.0"

    @Option(name: .customLong("icon"), help: "Optional square source PNG copied to Resources/AppIcon.png.")
    var iconSource: String?

    @Option(help: "Output directory (defaults to the current directory).")
    var output: String = "."

    mutating func run() async throws {
        guard AppConfig.isValidProductName(name) else {
            throw ProjectError.invalidProductName(name)
        }
        let baseID = bundleID ?? "net.example.\(name)"
        guard AppConfig.isValidBundleID(baseID) else {
            throw ProjectError.invalidBundleID(baseID)
        }
        guard AppConfig.isValidVersion(deploymentTarget) else {
            throw ProjectError.invalidDeploymentTarget(deploymentTarget)
        }

        let outputURL = URL(fileURLWithPath: output)
        _ = try ProjectGenerator.generate(
            baseURL: outputURL,
            options: .init(
                name: name,
                bundleID: baseID,
                deploymentTarget: deploymentTarget,
                iconSource: iconSource
            )
        )
        print("Created project at \(outputURL.appendingPathComponent(name).path)")
        print("Next steps:")
        print("  cd \(name)")
        print("  stupid-app build")
    }
}