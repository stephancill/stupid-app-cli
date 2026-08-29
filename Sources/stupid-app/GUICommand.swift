// The native macOS GUI (`stupid-app gui`).
//
// macOS-only. The entire body is gated behind `#if os(macOS)` so the packaged CLI still
// compiles on Linux; on a non-macOS host the `gui` subcommand is simply not registered.
//
// Commands are executed by spawning the current `stupid-app` binary as a subprocess with
// the same arguments the user would type on the command line, streaming stdout and stderr
// into a live log pane. This keeps the GUI thin and guarantees behavior identical to the
// CLI. The GUI is intentionally minimal: a toolbar with Doctor, Build, and Run, a project
// directory picker, and a status/log pane.

#if os(macOS)

import AppKit
import ArgumentParser
import Foundation
import SwiftUI

/// Strong reference so the AppDelegate (a weak `NSApplication.delegate`) survives the
/// `NSApplication.run()` loop.
@MainActor private var guiAppDelegate: AppDelegate?

/// `stupid-app gui`: launch the native macOS desktop application.
struct GUICommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "gui",
    abstract: "Launch the native macOS desktop GUI for stupid-app.",
    discussion: """
    Starts a SwiftUI/AppKit desktop app exposing a toolbar and menus that execute the
    CLI commands (Doctor, Build, Run) as subprocesses with live output. macOS-only.
    """
  )

  @MainActor
  mutating func run() async throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let delegate = AppDelegate()
    guiAppDelegate = delegate // retain for the lifetime of `app.run()`
    app.delegate = delegate

    app.run()
  }
}

/// A transport selection for `stupid-app run`.
enum RunMode: String, CaseIterable, Identifiable {
  case usb
  case network
  case simulator

  var id: Self { self }
  var label: String { rawValue }
}

/// AppKit application delegate: owns the shared `CommandRunner`, builds the window and the
/// menu bar, and forwards menu actions into the runner.
@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
  fileprivate let runner = CommandRunner()

  func applicationDidFinishLaunching(_ notification: Notification) {
    let app = NSApplication.shared

    app.mainMenu = Self.makeMainMenu(target: self)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 540),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "stupid-app"
    window.contentView = NSHostingView(rootView: RootView(runner: runner))
    window.center()
    window.makeKeyAndOrderFront(nil)

    app.activate(ignoringOtherApps: true)
  }

  func applicationWillTerminate(_ notification: Notification) {
    runner.stop()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  // MARK: - Menu actions

  @objc private func menuDoctor() { runner.doctor() }
  @objc private func menuBuild() { runner.build() }
  @objc private func menuRunUSB() { runner.run(mode: .usb) }
  @objc private func menuRunNetwork() { runner.run(mode: .network) }
  @objc private func menuRunSimulator() { runner.run(mode: .simulator) }

  private static func makeMainMenu(target: AnyObject) -> NSMenu {
    let main = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu(title: "stupid-app")
    appItem.submenu = appMenu
    appMenu.addItem(
      withTitle: "About stupid-app",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: ""
    )
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Hide stupid-app",
      action: #selector(NSApplication.hide(_:)),
      keyEquivalent: "h"
    )
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Quit stupid-app",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    main.addItem(appItem)

    let actionsItem = NSMenuItem(title: "Actions", action: nil, keyEquivalent: "")
    let actionsMenu = NSMenu(title: "Actions")
    actionsItem.submenu = actionsMenu

    actionsMenu.addItem(withTitle: "Doctor", action: #selector(menuDoctor), keyEquivalent: "")
    actionsMenu.addItem(withTitle: "Build", action: #selector(menuBuild), keyEquivalent: "b")

    let runItem = NSMenuItem(title: "Run", action: nil, keyEquivalent: "")
    let runMenu = NSMenu(title: "Run")
    runMenu.addItem(withTitle: "Over USB", action: #selector(menuRunUSB), keyEquivalent: "r")
    runMenu.addItem(withTitle: "Over Network…", action: #selector(menuRunNetwork), keyEquivalent: "")
    runMenu.addItem(withTitle: "In Simulator…", action: #selector(menuRunSimulator), keyEquivalent: "")
    runItem.submenu = runMenu
    actionsMenu.addItem(runItem)

    for item in actionsMenu.items {
      item.target = target
    }
    main.addItem(actionsItem)

    return main
  }
}

/// Owns the subprocess execution and the observable UI state. `@MainActor` makes this type
/// implicitly `Sendable`, so it can be captured by the subprocess I/O closure handlers.
@MainActor
final class CommandRunner: ObservableObject {
  @Published var output = ""
  @Published var isRunning = false
  @Published var runningLabel: String?
  @Published var statusText = "Idle"

  @Published var projectPath = FileManager.default.currentDirectoryPath
  @Published var runMode: RunMode = .usb
  @Published var udid = ""

  /// Cap on kept output characters; the oldest text is dropped beyond this.
  private let maxOutputCharacters = 200_000
  private var process: Process?
  private var canceledByUser = false

  // MARK: - Public actions

  func chooseProject() {
    guard !isRunning else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Choose the directory containing stupid-app.yml (or an iOS project)."
    if panel.runModal() == .OK, let url = panel.url {
      projectPath = url.path
    }
  }

  func doctor() {
    start(arguments: ["doctor"], label: "doctor")
  }

  func build() {
    start(arguments: ["build"], label: "build")
  }

  func run(mode: RunMode = .usb) {
    var args = ["run"]
    switch mode {
    case .usb:
      args += ["--usb"]
    case .network:
      args += ["--network"]
      if !udid.isEmpty { args += ["--udid", udid] }
    case .simulator:
      args += ["--simulator"]
      if !udid.isEmpty { args += ["--udid", udid] }
    }
    start(arguments: args, label: "run \(mode.label)")
  }

  func stop() {
    guard let process else { return }
    canceledByUser = true
    process.terminate()
  }

  // MARK: - Subprocess management

  private func start(arguments: [String], label: String) {
    guard !isRunning else {
      statusText = "Busy — cannot start \(label)"
      return
    }

    let executable = Bundle.main.executableURL
      ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let proc = Process()
    proc.executableURL = executable
    proc.arguments = arguments
    proc.currentDirectoryURL = URL(fileURLWithPath: projectPath)

    let stdout = Pipe()
    let stderr = Pipe()
    proc.standardOutput = stdout
    proc.standardError = stderr

    canceledByUser = false
    output = ""
    isRunning = true
    runningLabel = label
    statusText = "Running: \(label)"
    output += "── stupid-app \(label) ──\n"

    do {
      try proc.run()
    } catch {
      output += "\nFailed to launch stupid-app: \(error.localizedDescription)\n"
      statusText = "Launch failed"
      isRunning = false
      runningLabel = nil
      return
    }

    self.process = proc

    let outHandle = stdout.fileHandleForReading
    let errHandle = stderr.fileHandleForReading
    outHandle.readabilityHandler = Self.makeReadHandler(runner: self)
    errHandle.readabilityHandler = Self.makeReadHandler(runner: self)

    proc.terminationHandler = { [weak self] p in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.finish(proc: p)
      }
    }
  }

  /// A readability handler that forwards decoded output to the main-actor append path.
  private static func makeReadHandler(runner: CommandRunner) -> @Sendable (FileHandle) -> Void {
    { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      Task { @MainActor [weak runner] in
        runner?.appendText(String(data: data, encoding: .utf8) ?? "")
      }
    }
  }

  private func appendText(_ text: String) {
    output += text
    if output.count > maxOutputCharacters {
      output = String(output.dropFirst(output.count - maxOutputCharacters))
    }
  }

  private func finish(proc: Process) {
    let status: String
    if canceledByUser {
      status = "Stopped"
      canceledByUser = false
    } else {
      status = proc.terminationStatus == 0
        ? "Completed"
        : "Failed (exit \(proc.terminationStatus))"
    }
    output += "\n\n── \(runningLabel ?? "command") finished: \(status) ──\n"
    statusText = status
    isRunning = false
    runningLabel = nil
    self.process = nil
  }
}

/// The SwiftUI toolbar, status line, and live log.
private struct RootView: View {
  @ObservedObject var runner: CommandRunner

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      toolbar
      Divider()
      statusLine
      logView
    }
    .padding(16)
    .frame(minWidth: 560, minHeight: 360)
  }

  private var toolbar: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text("Project:")
        TextField("path to project", text: $runner.projectPath)
          .textFieldStyle(.roundedBorder)
        Button("Choose…") { runner.chooseProject() }
          .disabled(runner.isRunning)
      }

      HStack(spacing: 8) {
        Button("Doctor") { runner.doctor() }
          .disabled(runner.isRunning)
        Button("Build") { runner.build() }
          .disabled(runner.isRunning)

        Picker("Run", selection: $runner.runMode) {
          ForEach(RunMode.allCases) { mode in
            Text(mode.label).tag(mode)
          }
        }
        .pickerStyle(.menu)
        .fixedSize()

        TextField("UDID (optional)", text: $runner.udid)
          .textFieldStyle(.roundedBorder)
          .frame(width: 160)

        Button("Run") { runner.run(mode: runner.runMode) }
          .disabled(runner.isRunning)

        if runner.isRunning {
          ProgressView().controlSize(.small)
          Button("Stop") { runner.stop() }
        }
      }
    }
  }

  private var statusLine: some View {
    HStack {
      Circle()
        .fill(statusColor)
        .frame(width: 10, height: 10)
      Text(runner.statusText)
        .font(.caption)
      Spacer()
      Button("Clear") { runner.output = "" }
        .disabled(runner.output.isEmpty)
    }
  }

  private var statusColor: Color {
    if runner.isRunning { return .orange }
    switch runner.statusText {
    case "Completed": return .green
    case "Idle": return .gray
    default: return .red
    }
  }

  private var logView: some View {
    ScrollViewReader { proxy in
      ScrollView {
        Text(runner.output)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .id("log-bottom")
      }
      .onChange(of: runner.output) { _, _ in
        withAnimation(.none) {
          proxy.scrollTo("log-bottom", anchor: .bottom)
        }
      }
      .background(Color.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
    }
  }
}

#endif