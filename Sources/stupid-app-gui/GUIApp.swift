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
enum RunMode: String, CaseIterable, Identifiable, Sendable {
  case usb, network, simulator
  var id: Self { self }
  var label: String { rawValue }
}

/// One runnable target shown in the device list (a simulator, a USB device, or a device
/// with a saved network pairing record).
struct RunTarget: Identifiable, Sendable {
  let kind: String       // "Simulator" | "USB" | "Network"
  let name: String
  let mode: RunMode
  let udid: String?
  let detail: String     // state for simulators, transport note for devices

  var id: String { "\(kind)/\(udid ?? name)" }
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
  @Published var selectedTargetID: String?

  @Published var availableTargets: [RunTarget] = []
  @Published var isRefreshingDevices = false
  @Published var devicesError: String?

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

  /// The currently selected device target from the dropdown, if any.
  var selectedTarget: RunTarget? {
    guard let selectedTargetID else { return nil }
    return availableTargets.first { $0.id == selectedTargetID }
  }

  /// Runs the command on the currently selected device target. No-op when none.
  func runSelected() {
    guard let target = selectedTarget else {
      statusText = "Select a device to run on first."
      return
    }
    run(on: target)
  }

  /// Runs on a specific device target from the device list or dropdown.
  func run(on target: RunTarget) {
    var args = ["run"]
    switch target.mode {
    case .usb:
      args += ["--usb"]
    case .network:
      args += ["--network"]
    case .simulator:
      args += ["--simulator"]
    }
    if let udid = target.udid {
      args += ["--udid", udid]
    }
    start(arguments: args, label: "run on \(target.name)")
  }

  func stop() {
    guard let process else { return }
    canceledByUser = true
    process.terminate()
  }

  // MARK: - Device inventory

  /// Refreshes the runnable-device list from `simulators --json` and `device list --json`,
  /// off the main thread so the UI stays responsive.
  func refreshDevices() {
    guard let bin = resolveBin() else {
      devicesError = "Cannot find the stupid-app binary."
      return
    }
    guard !isRefreshingDevices else { return }
    isRefreshingDevices = true
    devicesError = nil

    let binURL = bin
    Task.detached(priority: .userInitiated) {
      let sim = Self.capture(bin: binURL, arguments: ["simulators", "--json"])
      let dev = Self.capture(bin: binURL, arguments: ["device", "list", "--json"])
      let targets = Self.parseTargets(sim: sim, dev: dev)
      let errorText = Self.summarizeErrors(sim: sim, dev: dev)
      await MainActor.run {
        let runner = CommandRunner.shared
        runner.availableTargets = targets
        runner.devicesError = errorText
        runner.isRefreshingDevices = false
      }
    }
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

  // MARK: - Device inventory helpers (callable from a background task)

  nonisolated private struct CaptureResult: Sendable {
    let status: Int
    let stdout: String
    let stderr: String
  }

  private struct SimDevice: Decodable {
    let name: String
    let udid: String
    let state: String
  }

  private struct SimRoot: Decodable {
    let devices: [SimDevice]
  }

  private struct NetworkPairing: Decodable {
    let identifier: String
    let udid: String?
  }

  private struct DeviceListRoot: Decodable {
    let usbDevices: [String]
    let networkPairings: [NetworkPairing]
  }

  /// Runs a short CLI call and captures its output synchronously. Blocking, so it is
  /// intended to be invoked from a background task.
  nonisolated private static func capture(bin: URL, arguments: [String]) -> CaptureResult {
    let proc = Process()
    proc.executableURL = bin
    proc.arguments = arguments

    let stdout = Pipe()
    let stderr = Pipe()
    proc.standardOutput = stdout
    proc.standardError = stderr

    do {
      try proc.run()
    } catch {
      return CaptureResult(status: -1, stdout: "", stderr: error.localizedDescription)
    }
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return CaptureResult(
      status: Int(proc.terminationStatus),
      stdout: String(data: outData, encoding: .utf8) ?? "",
      stderr: String(data: errData, encoding: .utf8) ?? ""
    )
  }

  /// Merges simulator and local-device listings into runnable targets.
  nonisolated private static func parseTargets(sim: CaptureResult, dev: CaptureResult) -> [RunTarget] {
    var targets: [RunTarget] = []

    if sim.status == 0, let data = sim.stdout.data(using: .utf8) {
      let json = (try? JSONDecoder().decode(SimRoot.self, from: data)) ?? SimRoot(devices: [])
      for device in json.devices {
        targets.append(
          RunTarget(
            kind: "Simulator",
            name: device.name,
            mode: .simulator,
            udid: device.udid,
            detail: device.state
          )
        )
      }
    }

    if dev.status == 0, let data = dev.stdout.data(using: .utf8) {
      if let json = try? JSONDecoder().decode(DeviceListRoot.self, from: data) {
        for udid in json.usbDevices {
          targets.append(
            RunTarget(kind: "USB", name: "USB Device", mode: .usb, udid: udid, detail: "connected")
          )
        }
        for pairing in json.networkPairings where pairing.udid != nil {
          targets.append(
            RunTarget(
              kind: "Network",
              name: "Paired Device",
              mode: .network,
              udid: pairing.udid,
              detail: "wireless pairing"
            )
          )
        }
      }
    }

    return targets.sorted { ($0.kind, $0.name.lowercased()) < ($1.kind, $1.name.lowercased()) }
  }

  /// Builds a short error note when a listing source failed, or nil when all succeeded.
  nonisolated private static func summarizeErrors(sim: CaptureResult, dev: CaptureResult) -> String? {
    var notes: [String] = []
    if sim.status != 0 {
      notes.append("simulators unavailable (\(sim.stderr)\(sim.stdout))")
    }
    if dev.status != 0 {
      notes.append("device list unavailable (\(dev.stderr.isEmpty ? dev.stdout : dev.stderr))")
    }
    return notes.isEmpty ? nil : notes.joined(separator: "; ")
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
      Button("Run Selected Device") { runner.runSelected() }
        .keyboardShortcut("r", modifiers: [.command])
      Button("Refresh Devices") { runner.refreshDevices() }
        .keyboardShortcut("r", modifiers: [.command, .shift])
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
    .frame(minWidth: 620, minHeight: 520)
    .onAppear {
      runner.refreshDevices()
    }
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
        Picker("Run:", selection: $runner.selectedTargetID) {
          Text("Choose a device…").tag(String?.none)
          ForEach(runner.availableTargets) { target in
            Text(targetLabel(target)).tag(Optional(target.id))
          }
        }
        .pickerStyle(.menu)
        .frame(minWidth: 220)
        .disabled(runner.availableTargets.isEmpty || runner.isRunning)

        if runner.isRefreshingDevices {
          ProgressView().controlSize(.small)
        }
        Button("Refresh") { runner.refreshDevices() }
          .disabled(runner.isRefreshingDevices || runner.isRunning)

        Button("Doctor") { runner.doctor() }
          .disabled(runner.isRunning)
        Button("Build") { runner.build() }
          .disabled(runner.isRunning)
        Button("Run") { runner.runSelected() }
          .disabled(runner.isRunning || runner.selectedTarget == nil)

        if runner.isRunning {
          ProgressView().controlSize(.small)
          Button("Stop") { runner.stop() }
        }
      }
    }
  }

  private func targetLabel(_ target: RunTarget) -> String {
    let device = target.kind == "Simulator" ? target.name : "\(target.kind) · \(target.name)"
    let trailer = target.kind == "Simulator" ? " (\(target.detail))" : ""
    return device + trailer
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