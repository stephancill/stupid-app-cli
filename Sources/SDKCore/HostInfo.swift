import Foundation
import SDKCore

/// Cross-platform host probing: detects the current host triple and Swift compiler
/// version so the importer can reject incompatible SDK bundles before installation.
public enum HostInfo {
    public struct Info: Equatable, Sendable {
        public var triple: String
        public var swiftMajor: Int
        public var swiftMinor: Int
    }

    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case swiftUnavailable(String)
        case malformedTargetInfo(String)

        public var description: String {
            switch self {
            case let .swiftUnavailable(output):
                return "Could not detect the host Swift compiler. \(output)"
            case let .malformedTargetInfo(output):
                return "Could not parse `swift -print-target-info` output. \(output)"
            }
        }
    }

    /// Runs `swift -print-target-info` and extracts the unversioned host triple and the
    /// Swift compiler major/minor version.
    public static func detect(swiftPath: String = "swift") throws -> Info {
        let executable = resolveExecutable(swiftPath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-print-target-info"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw Error.swiftUnavailable("'\(swiftPath)' could not be launched.")
        }
        process.waitUntilExit()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw Error.swiftUnavailable(String(decoding: err, as: UTF8.self))
        }

        struct TargetInfo: Decodable {
            struct Target: Decodable {
                var unversionedTriple: String
            }
            var compilerVersion: String
            var target: Target
        }

        guard let info = try? JSONDecoder().decode(TargetInfo.self, from: out) else {
            throw Error.malformedTargetInfo(String(decoding: out, as: UTF8.self))
        }

        // Parse "Swift version 6.2.4 (swift-6.2.4-RELEASE)".
        let versionComponents = info.compilerVersion
            .split(separator: " ")
            .map(String.init)
        guard let majorMinor = versionComponents.first(where: { $0.contains(".") })?.split(separator: ".").map(String.init),
              majorMinor.count >= 2,
              let major = Int(majorMinor[0]),
              let minor = Int(majorMinor[1]) else {
            throw Error.malformedTargetInfo(info.compilerVersion)
        }

        return Info(
            triple: info.target.unversionedTriple,
            swiftMajor: major,
            swiftMinor: minor
        )
    }

    /// Resolves a command name to an absolute path via PATH when it is not already one.
    public static func resolveExecutable(_ name: String) -> String {
        if name.contains("/") {
            return name
        }
        let pathEntries = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        for dir in pathEntries {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return name
    }
}
