import Foundation
import Testing

@testable import BuildCore

struct ProcessRunnerTests {
  @Test("drains verbose output without a pipe deadlock and retains its bounded tail")
  func drainsBoundedOutput() throws {
    let result = try ProcessRunner.run(
      executable: "/bin/sh",
      arguments: [
        "-c",
        "i=0; while [ $i -lt 5000 ]; do printf 'line-%04d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n' $i >&2; i=$((i+1)); done; exit 7",
      ],
      configuration: .init(maxOutputBytes: 512, timeoutSeconds: 10)
    )

    #expect(result.exitStatus == 7)
    #expect(result.stderr.hasPrefix("[earlier output truncated]\n"))
    #expect(result.stderr.contains("line-4999"))
    #expect(result.stderr.utf8.count <= 550)
  }

  @Test("times out and reports bounded subprocess diagnostics")
  func timesOutWithDiagnostics() {
    do {
      _ = try ProcessRunner.run(
        executable: "/bin/sh",
        arguments: [
          "-c", "printf 'waiting for device\\n' >&2; trap '' INT TERM; while :; do :; done",
        ],
        configuration: .init(
          maxOutputBytes: 512,
          timeoutSeconds: 0.2,
          terminationGraceSeconds: 0.1
        )
      )
      Issue.record("Expected the process to time out")
    } catch let error as ProcessError {
      #expect(error.description.contains("waiting for device"))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test("task cancellation stops the subprocess")
  func cancellationStopsSubprocess() async {
    let task = Task {
      try ProcessRunner.run(
        executable: "/bin/sh",
        arguments: ["-c", "while :; do :; done"],
        configuration: .init(timeoutSeconds: 30, terminationGraceSeconds: 0.1)
      )
    }
    try? await Task<Never, Never>.sleep(for: .milliseconds(100))
    task.cancel()

    do {
      _ = try await task.value
      Issue.record("Expected the subprocess to be cancelled")
    } catch let error as ProcessError {
      #expect(error.description.contains("was cancelled"))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  #if os(Linux)
    @Test("timeout kills Linux process-group descendants")
    func timeoutKillsProcessGroup() {
      do {
        _ = try ProcessRunner.run(
          executable: "/bin/sh",
          arguments: [
            "-c", "trap '' INT TERM; (trap '' INT TERM; while :; do :; done) & wait",
          ],
          configuration: .init(timeoutSeconds: 0.2, terminationGraceSeconds: 0.1)
        )
        Issue.record("Expected the process group to time out")
      } catch is ProcessError {
      } catch {
        Issue.record("Unexpected error: \(error)")
      }
    }
  #endif
}
