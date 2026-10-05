import ArgumentParser
import DeviceKit
import Foundation

struct UserspaceTunnelSpikeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "userspace-tunnel-spike",
    abstract: "Experimental wireless RSD/AFC/install/launch through lwIP, without elevation."
  )

  @Option(name: .long, help: "Pairing directory; defaults to the ordinary credential store.")
  var pairingDir: String?

  @Option(
    name: .customLong("pairing-host-id"),
    help: "Original host identity UUID when testing a copied pairing record.")
  var pairingHostIdentifier: String?

  @Option(name: .long, help: "Device UDID; defaults only when exactly one saved device exists.")
  var udid: String?

  @Option(name: .long, help: "Already development-signed IPA. Omit for RSD/AFC-only proof.")
  var ipa: String?

  @Option(name: .long, help: "Bundle identifier of the supplied IPA.")
  var bundleID: String?

  @Option(name: .long, help: "Operation timeout and TLS relay lifetime in seconds.")
  var timeout: Double = 300

  @Option(
    name: .customLong("transfer-mib"),
    help: "Round-trip and remove a temporary AFC file, from 0 to 32 MiB.")
  var transferMiB: Int = 0

  @Option(name: .customLong("repeat"), help: "Consecutive runs, including cleanup between runs.")
  var repetitions: Int = 1

  func run() throws {
    guard geteuid() != 0 else {
      throw ValidationError("Run the spike as an ordinary user, without sudo.")
    }
    guard timeout > 0, timeout.isFinite, timeout * 1_000 <= Double(Int32.max),
      (1...10).contains(repetitions), (0...32).contains(transferMiB)
    else {
      throw ValidationError("Use a positive bounded timeout and a repeat count from 1 to 10.")
    }
    #if os(Linux)
      let status = try String(contentsOfFile: "/proc/self/status", encoding: .utf8)
      if let line = status.split(separator: "\n").first(where: { $0.hasPrefix("CapEff:") }),
        let value = UInt64(line.split(whereSeparator: \.isWhitespace).last ?? "", radix: 16),
        value & (1 << 12) != 0
      {
        throw ValidationError("Remove CAP_NET_ADMIN before running this proof.")
      }
    #endif
    guard (ipa == nil) == (bundleID == nil) else {
      throw ValidationError("Supply --ipa and --bundle-id together, or omit both.")
    }
    if let pairingHostIdentifier, UUID(uuidString: pairingHostIdentifier) == nil {
      throw ValidationError("--pairing-host-id must be the original pairing host's UUID.")
    }
    let directory =
      pairingDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".stupid-app/credentials/pairing", isDirectory: true)
    let target: String
    if let udid {
      target = udid
    } else {
      let devices = Set(try RemotePairing.savedPairings(in: directory).compactMap(\.udid))
      guard devices.count == 1, let device = devices.first else {
        throw ValidationError(
          "Select --udid explicitly when there is not exactly one saved device.")
      }
      target = device
    }
    let ipaURL = ipa.map { URL(fileURLWithPath: $0) }
    if let ipaURL, !FileManager.default.isReadableFile(atPath: ipaURL.path) {
      throw ValidationError("The supplied IPA is not readable.")
    }
    for run in 1...repetitions {
      print("Userspace proof \(run)/\(repetitions): ordinary UID, no TUN or route operations.")
      do {
        try UserspaceNetworkSpike.run(
          pairingDirectory: directory, udid: target, ipa: ipaURL, bundleID: bundleID,
          timeoutSeconds: timeout, transferMiB: transferMiB,
          pairingHostIdentifier: pairingHostIdentifier, progress: { print($0) })
      } catch {
        throw ValidationError(RemotePairing.redact(detail: String(describing: error), udid: target))
      }
      print("Userspace proof \(run) passed; tunnel workers stopped.")
    }
  }
}

UserspaceTunnelSpikeCommand.main()
