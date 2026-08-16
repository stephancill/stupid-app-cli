import Foundation

/// A bounded subprocess runner. Captures bounded stdout/stderr, honors timeouts, and
/// reports exit status explicitly so failures are never silently absorbed.
public struct ProcessRunner {
    public struct Result: Sendable {
        public var exitStatus: Int32
        public var stdout: String
        public var stderr: String

        public var succeeded: Bool { exitStatus == 0 }
    }

    public struct Configuration: Sendable {
        /// Maximum bytes of each stream retained in memory.
        public var maxOutputBytes: Int
        public var timeoutSeconds: Double

        public init(maxOutputBytes: Int = 20_000, timeoutSeconds: Double = 600) {
            self.maxOutputBytes = maxOutputBytes
            self.timeoutSeconds = timeoutSeconds
        }
    }

    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: URL? = nil,
        configuration: Configuration = Configuration()
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed(executable, error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(configuration.timeoutSeconds)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw ProcessError.timeout(executable, configuration.timeoutSeconds)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let outData = readBounded(from: stdout.fileHandleForReading, max: configuration.maxOutputBytes)
        let errData = readBounded(from: stderr.fileHandleForReading, max: configuration.maxOutputBytes)

        return Result(
            exitStatus: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    private static func readBounded(from handle: FileHandle, max: Int) -> Data {
        var data = Data()
        let chunk = 4096
        while let next = try? handle.read(upToCount: chunk), !next.isEmpty {
            data.append(next)
            if data.count > max {
                data = data.prefix(max)
                break
            }
        }
        return data
    }
}

public enum ProcessError: Error, Equatable, Sendable, CustomStringConvertible {
    case launchFailed(String, String)
    case timeout(String, Double)

    public var description: String {
        switch self {
        case let .launchFailed(executable, message):
            return "Could not launch '\(executable)': \(message)"
        case let .timeout(executable, seconds):
            return "'\(executable)' timed out after \(Int(seconds)) seconds."
        }
    }
}