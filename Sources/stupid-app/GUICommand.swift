// The macOS `stupid-app gui` entry point.
//
// macOS-only: the body is gated behind `#if os(macOS)` so the CLI still compiles on Linux
// and the subcommand is only registered there.
//
// The actual desktop UI lives in a standalone SwiftUI executable (`stupid-app-gui`, target
// in this package). Running the GUI in its own process avoids the main-actor starvation that
// occurs when an ArgumentParser async main embeds `NSApplication.run()`, and keeps the CLI
// a thin launcher: spawn the GUI binary, forward the resolved CLI path via `STUPID_APP_BIN`
// so the GUI re-invokes commands as subprocesses, await its exit, and propagate its status.

#if os(macOS)

import ArgumentParser
import Foundation

/// `stupid-app gui`: launch the native macOS desktop application.
struct GUICommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "gui",
    abstract: "Launch the native macOS desktop GUI for stupid-app.",
    discussion: """
    Runs the standalone SwiftUI desktop app (the `stupid-app-gui` executable that sits
    beside this binary). The GUI exposes a toolbar and menus that run the CLI commands
    (Doctor, Build, Run) as subprocesses with live output. macOS-only.
    """
  )

  mutating func run() throws {
    let cliURL = (Bundle.main.executableURL
      ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()

    let guiURL = cliURL
      .deletingLastPathComponent()
      .appendingPathComponent("stupid-app-gui")

    guard FileManager.default.fileExists(atPath: guiURL.path) else {
      throw CommandError.missingGUI(guiURL.path)
    }

    let proc = Process()
    proc.executableURL = guiURL
    var env = ProcessInfo.processInfo.environment
    env["STUPID_APP_BIN"] = cliURL.path
    proc.environment = env

    do {
      try proc.run()
    } catch {
      throw CommandError.failedToLaunch(guiURL.path, error)
    }

    proc.waitUntilExit()
    if proc.terminationStatus != 0 {
      throw ExitCode(proc.terminationStatus)
    }
  }
}

private struct CommandError: LocalizedError {
  let message: String
  var errorDescription: String? { message }

  init(_ message: String) { self.message = message }

  static func missingGUI(_ path: String) -> CommandError {
    CommandError(
      "Cannot find the GUI executable at \(path). Build it with `swift build` "
        + "so `stupid-app-gui` sits next to `stupid-app`."
    )
  }

  static func failedToLaunch(_ path: String, _ error: Error) -> CommandError {
    CommandError("Failed to launch the GUI at \(path): \(error.localizedDescription)")
  }
}

#endif