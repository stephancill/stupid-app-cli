import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

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
    /// Time allowed after interrupt and terminate signals before escalating.
    public var terminationGraceSeconds: Double

    public init(
      maxOutputBytes: Int = 20_000,
      timeoutSeconds: Double = 600,
      terminationGraceSeconds: Double = 1
    ) {
      self.maxOutputBytes = maxOutputBytes
      self.timeoutSeconds = timeoutSeconds
      self.terminationGraceSeconds = terminationGraceSeconds
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
    let ownsProcessGroup: Bool
    #if os(Linux)
      // Foundation launches Linux children as process-group leaders. Signal that
      // group directly so descendants cannot survive timeout or cancellation.
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
      ownsProcessGroup = true
    #else
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
      ownsProcessGroup = false
    #endif
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

    let outDrainer = OutputDrainer(
      handle: stdout.fileHandleForReading, maxBytes: configuration.maxOutputBytes)
    let errDrainer = OutputDrainer(
      handle: stderr.fileHandleForReading, maxBytes: configuration.maxOutputBytes)
    outDrainer.start()
    errDrainer.start()

    let deadline = Date().addingTimeInterval(configuration.timeoutSeconds)
    while process.isRunning {
      if Task<Never, Never>.isCancelled {
        stop(
          process: process,
          ownsProcessGroup: ownsProcessGroup,
          graceSeconds: configuration.terminationGraceSeconds
        )
        finishReading(outDrainer: outDrainer, errDrainer: errDrainer)
        throw ProcessError.cancelled(
          executable, diagnostic(outDrainer: outDrainer, errDrainer: errDrainer))
      }
      if Date() > deadline {
        stop(
          process: process,
          ownsProcessGroup: ownsProcessGroup,
          graceSeconds: configuration.terminationGraceSeconds
        )
        finishReading(outDrainer: outDrainer, errDrainer: errDrainer)
        throw ProcessError.timeout(
          executable,
          configuration.timeoutSeconds,
          diagnostic(outDrainer: outDrainer, errDrainer: errDrainer)
        )
      }
      Thread.sleep(forTimeInterval: 0.05)
    }

    finishReading(outDrainer: outDrainer, errDrainer: errDrainer)

    return Result(
      exitStatus: process.terminationStatus,
      stdout: outDrainer.string,
      stderr: errDrainer.string
    )
  }

  private static func finishReading(
    outDrainer: OutputDrainer,
    errDrainer: OutputDrainer
  ) {
    outDrainer.finish()
    errDrainer.finish()
  }

  private static func stop(process: Process, ownsProcessGroup: Bool, graceSeconds: Double) {
    for signal in [SIGINT, SIGTERM, SIGKILL] {
      guard process.isRunning else { return }
      send(signal: signal, to: process, ownsProcessGroup: ownsProcessGroup)
      let deadline = Date().addingTimeInterval(graceSeconds)
      while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
      }
    }
    if process.isRunning {
      process.terminate()
    }
    process.waitUntilExit()
  }

  private static func send(signal: Int32, to process: Process, ownsProcessGroup: Bool) {
    let pid = process.processIdentifier
    _ = kill(ownsProcessGroup ? -pid : pid, signal)
  }

  private static func diagnostic(
    outDrainer: OutputDrainer,
    errDrainer: OutputDrainer
  ) -> String {
    let stderr = errDrainer.string
    return stderr.isEmpty ? outDrainer.string : stderr
  }
}

private final class OutputDrainer: @unchecked Sendable {
  private let handle: FileHandle
  private let collector: BoundedOutputCollector
  private let group = DispatchGroup()
  private let queue = DispatchQueue(label: "stupid-app.process-output.\(UUID().uuidString)")

  init(handle: FileHandle, maxBytes: Int) {
    self.handle = handle
    collector = BoundedOutputCollector(maxBytes: maxBytes)
  }

  func start() {
    group.enter()
    queue.async { [self] in
      defer { group.leave() }
      while let next = try? handle.read(upToCount: 4096), !next.isEmpty {
        collector.append(next)
      }
    }
  }

  func finish() {
    if group.wait(timeout: .now() + 1) == .timedOut {
      try? handle.close()
      group.wait()
    }
  }

  var string: String { collector.string }
}

private final class BoundedOutputCollector: @unchecked Sendable {
  private let lock = NSLock()
  private let maxBytes: Int
  private var data = Data()
  private var truncated = false

  init(maxBytes: Int) {
    self.maxBytes = max(0, maxBytes)
  }

  func append(_ next: Data) {
    guard !next.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    guard maxBytes > 0 else {
      truncated = true
      return
    }
    if next.count >= maxBytes {
      data = Data(next.suffix(maxBytes))
      truncated = true
      return
    }
    let overflow = data.count + next.count - maxBytes
    if overflow > 0 {
      data.removeFirst(overflow)
      truncated = true
    }
    data.append(next)
  }

  var string: String {
    lock.lock()
    defer { lock.unlock() }
    let output = String(decoding: data, as: UTF8.self)
    return truncated ? "[earlier output truncated]\n\(output)" : output
  }
}

public enum ProcessError: Error, Equatable, Sendable, CustomStringConvertible {
  case launchFailed(String, String)
  case timeout(String, Double, String)
  case cancelled(String, String)

  public var description: String {
    switch self {
    case .launchFailed(let executable, let message):
      return "Could not launch '\(executable)': \(message)"
    case .timeout(let executable, let seconds, let detail):
      return
        "'\(executable)' timed out after \(Int(seconds)) seconds.\(detail.isEmpty ? "" : "\n\(detail)")"
    case .cancelled(let executable, let detail):
      return "'\(executable)' was cancelled.\(detail.isEmpty ? "" : "\n\(detail)")"
    }
  }
}
