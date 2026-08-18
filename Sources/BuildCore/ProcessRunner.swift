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
    #if canImport(Darwin)
      return try runOnDarwin(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        configuration: configuration
      )
    #else
      return try runOnLinux(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        configuration: configuration
      )
    #endif
  }

  #if canImport(Darwin)

    /// Darwin launch path. Foundation's `Process` does not expose the posix_spawn
    /// attribute set, so this path spawns the child directly with
    /// `POSIX_SPAWN_SETPGROUP` (pgroup 0: the child becomes its own process-group
    /// leader). Signaling the group (`kill(-pid)`) then reaches descendants, so
    /// timeout and cancellation cannot leave a helper or its tunnel alive.
    private static func runOnDarwin(
      executable: String,
      arguments: [String],
      environment: [String: String],
      workingDirectory: URL?,
      configuration: Configuration
    ) throws -> Result {
      let stdout = Pipe()
      let stderr = Pipe()

      // posix_spawn requires a stable argv/envp whose C strings live until spawn
      // returns, so each string is copied into heap storage that outlives the
      // call and freed afterward.
      let (argv, argvRelease) = makeCStringArray([executable] + arguments)
      defer { argvRelease() }
      let (envp, envpRelease) = makeCStringArray(
        environment.map { "\($0.key)=\($0.value)" })
      defer { envpRelease() }

      var attributes: posix_spawnattr_t?
      let attributeResult = posix_spawnattr_init(&attributes)
      guard attributeResult == 0 else {
        throw ProcessError.launchFailed(executable, "posix_spawnattr_init failed")
      }
      defer { posix_spawnattr_destroy(&attributes) }
      let attributeFlags = POSIX_SPAWN_SETPGROUP
      posix_spawnattr_setflags(&attributes, Int16(attributeFlags))

      var actions: posix_spawn_file_actions_t?
      let actionsResult = posix_spawn_file_actions_init(&actions)
      guard actionsResult == 0 else {
        throw ProcessError.launchFailed(executable, "posix_spawn_file_actions_init failed")
      }
      defer { posix_spawn_file_actions_destroy(&actions) }
      posix_spawn_file_actions_adddup2(
        &actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
      posix_spawn_file_actions_adddup2(
        &actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
      if let workingDirectory {
        let result = workingDirectory.path.withCString { path in
          posix_spawn_file_actions_addchdir_np(&actions, path)
        }
        if result != 0 {
          throw ProcessError.launchFailed(
            executable, "posix_spawn chdir failed with error \(result)")
        }
      }

      var pid: pid_t = 0
      let spawnResult = executable.withCString { path in
        argv.withUnsafeBufferPointer { argvBuffer in
          envp.withUnsafeBufferPointer { envpBuffer in
            posix_spawn(
              &pid,
              path,
              &actions,
              &attributes,
              argvBuffer.baseAddress,
              envpBuffer.baseAddress)
          }
        }
      }
      guard spawnResult == 0 else {
        throw ProcessError.launchFailed(executable, "posix_spawn failed with error \(spawnResult)")
      }
      try? stdout.fileHandleForWriting.close()
      try? stderr.fileHandleForWriting.close()

      let outDrainer = OutputDrainer(
        handle: stdout.fileHandleForReading, maxBytes: configuration.maxOutputBytes)
      let errDrainer = OutputDrainer(
        handle: stderr.fileHandleForReading, maxBytes: configuration.maxOutputBytes)
      outDrainer.start()
      errDrainer.start()

      let deadline = Date().addingTimeInterval(configuration.timeoutSeconds)
      var status: Int32 = 0
      while true {
        let waited = waitpid(pid, &status, WNOHANG)
        if waited == pid {
          break
        }
        if waited < 0, errno != EINTR {
          throw ProcessError.launchFailed(executable, "waitpid failed")
        }
        if Task<Never, Never>.isCancelled {
          stopDarwin(pid: pid, graceSeconds: configuration.terminationGraceSeconds)
          finishReading(outDrainer: outDrainer, errDrainer: errDrainer)
          throw ProcessError.cancelled(
            executable, diagnostic(outDrainer: outDrainer, errDrainer: errDrainer))
        }
        if Date() > deadline {
          stopDarwin(pid: pid, graceSeconds: configuration.terminationGraceSeconds)
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
      let exitStatus: Int32
      if status & 0x7f == 0 {
        exitStatus = (status >> 8) & 0xff
      } else {
        exitStatus = status & 0x7f
      }
      return Result(
        exitStatus: exitStatus,
        stdout: outDrainer.string,
        stderr: errDrainer.string
      )
    }

    private static func stopDarwin(pid: pid_t, graceSeconds: Double) {
      for signal in [SIGINT, SIGTERM, SIGKILL] {
        if isRunning(pid: pid) == false { return }
        _ = kill(-pid, signal)
        let deadline = Date().addingTimeInterval(graceSeconds)
        while isRunning(pid: pid), Date() < deadline {
          Thread.sleep(forTimeInterval: 0.05)
        }
      }
    }

    private static func isRunning(pid: pid_t) -> Bool {
      var status: Int32 = 0
      let result = waitpid(pid, &status, WNOHANG)
      return result == 0
    }

    /// Builds a null-terminated C string array with a stable backing allocation.
    /// The returned array and its strings are valid until the returned release
    /// closure is invoked.
    private static func makeCStringArray(
      _ values: [String]
    ) -> (array: [UnsafeMutablePointer<CChar>?], release: () -> Void) {
      var array: [UnsafeMutablePointer<CChar>?] = []
      var allocated: [UnsafeMutablePointer<CChar>] = []
      for value in values {
        let cString = value.utf8CString
        let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: cString.count)
        cString.withUnsafeBufferPointer { buffer in
          pointer.initialize(from: buffer.baseAddress!, count: cString.count)
        }
        allocated.append(pointer)
        array.append(pointer)
      }
      array.append(nil)
      return (
        array,
        {
          for pointer in allocated {
            pointer.deallocate()
          }
        }
      )
    }

  #else

    private static func runOnLinux(
      executable: String,
      arguments: [String],
      environment: [String: String],
      workingDirectory: URL?,
      configuration: Configuration
    ) throws -> Result {
      let process = Process()
      let ownsProcessGroup: Bool
      // Foundation launches Linux children as process-group leaders. Signal that
      // group directly so descendants cannot survive timeout or cancellation.
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
      ownsProcessGroup = true
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

  #endif

  private static func finishReading(
    outDrainer: OutputDrainer,
    errDrainer: OutputDrainer
  ) {
    outDrainer.finish()
    errDrainer.finish()
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
