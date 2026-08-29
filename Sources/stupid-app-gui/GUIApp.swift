// The native macOS GUI for `stupid-app` (`stupid-app gui`).
//
// This is a standalone SwiftUI `@main` App executable so the AppKit/SwiftUI runtime and the
// Swift concurrency main actor are driven by SwiftUI's own run loop. Embedding the GUI into
// the CLI's ArgumentParser async main caused main-actor starvation (deferred
// `Task { @MainActor }` blocks, never ran), so `stupid-app gui` launches this executable as a
// separate process and forwards a `STUPID_APP_BIN` env var pointing at the CLI binary.
// Commands are then re-invoked as subprocesses with live output.
//
// macOS-only: the whole file is gated behind `#if os(macOS)` so `swift build` still succeeds
// (compiling an empty `stupid-app-gui` executable) on Linux.

#if os(macOS)

import AppKit
import SwiftUI

/// How `stupid-app run` is transported.
enum RunMode: String, CaseIterable, Identifiable {
  case usb, network, simulator
  var id: Self { self }
  var label: String { rawValue }
}

/// Owns subprocess execution and observable UI state. Shared by the toolbar, the window
/// content, and the app menu commands. `@MainActor` makes it implicitly `Sendable`, so it
/// can be captured by the subprocess I/O closure handlers.
@MainActor
final class CommandRunner: ObservableObject {
  static let shared = CommandRunner()

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

  private var resolvedBin: URL?

  /// The CLI binary to invoke. Prefer the `STUPID_APP_BIN` env var (set by `stupid-app
  /// gui`), then the sibling `stupid-app` next to this executable.
  private func resolveBin() -> URL? {
    if let resolvedBin { return resolvedBin }
    var candidate: URL?
    if let override = ProcessInfo.processInfo.environment["STUPID_APP_BIN"], !override.isEmpty {
      candidate = URL(fileURLWithPath: override)
    } else if let executable = Bundle.main.executableURL {
      candidate = executable.deletingLastPathComponent().appendingPathComponent("stupid-app")
    }
    resolvedBin = candidate
    return candidate
  }

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
    guard let bin = resolveBin() else {
      statusText = "Cannot find the stupid-app binary"
      output = "Could not locate the `stupid-app` executable to run `\(label)`.\n"
      return
    }

    let proc = Process()
    proc.executableURL = bin
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
    outHandle.readabilityHandler = makeReadHandler()
    errHandle.readabilityHandler = makeReadHandler()

    proc.terminationHandler = { [weak self] p in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.finish(proc: p)
      }
    }
  }

  private func makeReadHandler() -> @Sendable (FileHandle) -> Void {
    { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      Task { @MainActor [weak self] in
        self?.appendText(String(data: data, encoding: .utf8) ?? "")
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

@main
struct GUIApp: App {
  var body: some Scene {
    WindowGroup("stupid-app") {
      RootView()
    }
    .commands {
      AppMenuCommands()
    }
  }
}

/// App menu: an Actions menu driving the shared runner.
struct AppMenuCommands: Commands {
  @ObservedObject private var runner = CommandRunner.shared

  var body: some Commands {
    CommandMenu("Actions") {
      Button("Doctor") { runner.doctor() }
        .keyboardShortcut("D", modifiers: [.command])
      Button("Build") { runner.build() }
        .keyboardShortcut("b", modifiers: [.command])
      Divider()
      Menu("Run") {
        Button("Over USB") { runner.run(mode: .usb) }
          .keyboardShortcut("r", modifiers: [.command])
        Button("Over Network…") { runner.run(mode: .network) }
        Button("In Simulator…") { runner.run(mode: .simulator) }
      }
    }
  }
}

/// The toolbar, status line, and live log.
struct RootView: View {
  @ObservedObject private var runner = CommandRunner.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      toolbar
      Divider()
      statusLine
      logView
    }
    .padding(12)
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

        Button("Doctor") { runner.doctor() }
          .disabled(runner.isRunning)
        Button("Build") { runner.build() }
          .disabled(runner.isRunning)
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