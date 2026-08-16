import ArgumentParser
import Foundation
import BuildCore
import ProjectCore
import SDKCore

/// `stupid-app build`: graphs the project, builds it with the imported Swift SDK,
/// assembles an unsigned `.app`, and validates the Mach-O output.
struct BuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build an unsigned iOS .app from the project with the imported SDK."
    )

    /// Build configuration; defaults to an internal macro so the `.build/...` output
    /// matches SwiftPM's directory layout (`debug`/`release`).
    enum Configuration: String, CaseIterable, ExpressibleByArgument {
        case debug
        case release
    }

    @Option(name: .customLong("configuration"), help: "Build configuration (debug|release).")
    var configuration: Configuration = .debug

    @Option(name: .customLong("sdk-id"), help: "Imported Swift SDK identifier (default stupid-app-ios).")
    var sdkID: String = "stupid-app-ios"

    @Option(name: .customLong("sdk-version"), help: "Override the SDK version reported in LC_BUILD_VERSION.")
    var sdkVersionOverride: String?

    @Option(name: .customLong("swift"), help: "Path to the host `swift` executable.")
    var swiftPath: String = "swift"

    mutating func run() async throws {
        let configURL = URL(fileURLWithPath: "stupid-app.yml")
        guard let data = try? Data(contentsOf: configURL) else {
            throw ProjectError.unreadableConfig(configURL.path)
        }
        let config = try AppConfig.decode(data)
        let projectRoot = URL(fileURLWithPath: ".")
        let planner = Planner(projectRoot: projectRoot, config: config, swiftPath: swiftPath)
        let plan = try planner.makePlan()

        let buildConfiguration: BuildConfiguration = configuration == .release ? .release : .debug
        let resolvedSDKID = sdkID
        let resolvedSwift = swiftPath
        let resolvedOverride = sdkVersionOverride

        guard SDKVersion.isInstalled(sdkID: resolvedSDKID, swiftPath: resolvedSwift) else {
            throw SDKVersion.Error.sdkNotInstalled(resolvedSDKID)
        }

        let packer = Packer(
            projectRoot: projectRoot,
            plan: plan,
            config: config,
            swiftPath: swiftPath,
            sdkID: sdkID,
            sdkVersion: { @Sendable in
                try SDKVersion.resolve(
                    sdkID: resolvedSDKID,
                    targetTriple: "arm64-apple-ios",
                    swiftPath: resolvedSwift,
                    override: resolvedOverride
                )
            },
            buildConfiguration: buildConfiguration
        )

        let appURL = try packer.pack()
        let executableURL = appURL.appendingPathComponent(plan.product)
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw BuildError.processingFailed("app assembly", "Assembled bundle has no executable.")
        }

        let info = try MachOInspector.inspect(at: executableURL)
        guard info.isMachO else {
            throw BuildError.processingFailed("validation", "Executable is not a Mach-O file.")
        }
        guard info.cpuArchitecture == "arm64" else {
            throw BuildError.processingFailed("validation", "Executable architecture is not arm64.")
        }

        print("Built \(plan.product).app at \(appURL.path)")
        if let platform = info.platform, let minOS = info.minimumOS, let sdk = info.sdkVersion {
            print("Executable: Mach-O \(info.cpuArchitecture ?? "unknown") \(platform) min \(minOS) sdk \(sdk)")
        }
    }
}