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
        abstract: "Build an unsigned iOS .app from the project (Xcode SDK in place or imported bundle)."
    )

    /// Build configuration; defaults to an internal macro so the `.build/...` output
    /// matches SwiftPM's directory layout (`debug`/`release`).
    enum Configuration: String, CaseIterable, ExpressibleByArgument {
        case debug
        case release
    }

    @Option(name: .customLong("configuration"), help: "Build configuration (debug|release).")
    var configuration: Configuration = .debug

    @Option(name: .customLong("sdk-id"), help: "Imported Swift SDK identifier (bundle hosts; default stupid-app-ios).")
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

        // Resolve the active host SDK mode once: with a usable Xcode, build in place
        // against Xcode's SDK without an artifact bundle; otherwise the imported
        // `stupid-app` bundle is required.
        let mode = HostSDKMode.detect()
        let toolchain = BuildToolchain.resolve(
            swiftPath: swiftPath,
            sdkID: sdkID,
            targetTriple: "arm64-apple-ios",
            mode: mode,
            sdkVersionOverride: sdkVersionOverride
        )
        let resolvedSwift = toolchain.swiftPath

        let planner = Planner(projectRoot: projectRoot, config: config, swiftPath: resolvedSwift)
        let plan = try planner.makePlan()

        let buildConfiguration: BuildConfiguration = configuration == .release ? .release : .debug
        if case .importedBundle = toolchain.sdkInput {
            guard SDKVersion.isInstalled(sdkID: sdkID, swiftPath: resolvedSwift) else {
                throw SDKVersion.Error.sdkNotInstalled(sdkID)
            }
        }

        let packer = Packer(
            projectRoot: projectRoot,
            plan: plan,
            config: config,
            swiftPath: resolvedSwift,
            sdkID: sdkID,
            sdkInput: toolchain.sdkInput,
            sdkVersion: toolchain.hostSDKVersion,
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