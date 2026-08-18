import ArgumentParser
import Foundation
import ProductCore

struct DoctorCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "doctor",
    abstract: "Check the host, toolchain, credentials, and device environment."
  )

  @Option(name: .customLong("project"), help: "Project directory to validate.")
  var project: String = "."

  @Option(name: .customLong("home"), help: "Credential store directory.")
  var home: String?

  @Option(name: .customLong("sdk-id"), help: "Imported Swift SDK identifier.")
  var sdkID: String = "stupid-app-ios"

  @Option(name: .customLong("swift"), help: "Path to the host `swift` executable.")
  var swiftPath: String = "swift"

  @Option(name: .customLong("sudo"), help: "Explicit path to sudo used by the CoreDevice helper.")
  var sudoPath: String?

  mutating func run() async throws {
    let credentialHome =
      home.map(URL.init(fileURLWithPath:))
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".stupid-app/credentials", isDirectory: true)
    let results = Doctor.run(
      input: .init(
        projectRoot: URL(fileURLWithPath: project).standardizedFileURL,
        credentialHome: credentialHome.standardizedFileURL,
        sdkID: sdkID,
        swiftPath: swiftPath,
        sudoPath: sudoPath
      ))

    for result in results {
      print("[\(result.status.rawValue.uppercased())] \(result.name): \(result.detail)")
    }

    let failures = results.filter { $0.status == .failure }.count
    let warnings = results.filter { $0.status == .warning }.count
    print("Doctor completed with \(failures) failure(s) and \(warnings) warning(s).")
    if failures > 0 {
      throw ExitCode.failure
    }
  }
}
