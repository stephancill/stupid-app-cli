import Foundation

/// Developer proof entrypoint for the process-local wireless transport.
/// USB launch and initial pairing retain their separate kernel transport.
public enum UserspaceNetworkSpike {
  public static func run(
    pairingDirectory: URL, udid: String, ipa: URL? = nil, bundleID: String? = nil,
    timeoutSeconds: Double = 60,
    transferMiB: Int = 0,
    pairingHostIdentifier: String? = nil,
    progress: @escaping @Sendable (String) -> Void
  ) throws {
    guard (ipa == nil) == (bundleID == nil) else {
      throw USBMuxClient.Error.invalidInput("supply both IPA and bundle identifier, or neither")
    }
    guard (0...32).contains(transferMiB) else {
      throw USBMuxClient.Error.invalidInput("transfer size must be from 0 to 32 MiB")
    }
    let identifiers = try RemotePairing.resolveIdentifiers(
      forRequestedUdid: udid, in: pairingDirectory)
    let advertisements = try RemotepairingDiscovery().browse(timeout: 15)
    guard !advertisements.isEmpty else { throw NativeNetworkRunner.Error.noAdvertisement }
    var failures: [String] = []
    for advertisement in advertisements {
      guard let port = advertisement.port else { continue }
      for address in advertisement.addresses.sorted() {
        for identifier in identifiers {
          var phase = "Pair-Verify"
          do {
            let record = try RemotePairing.Record.load(
              from: RemotePairing.recordURL(identifier: identifier, in: pairingDirectory))
            let client = RemotePairingTunnelClient(
              host: address.scopedIP, port: UInt16(port), timeoutSeconds: timeoutSeconds,
              pairingHostIdentifier: pairingHostIdentifier)
            let outcome = try client.establish(record: record)
            progress("Pair-Verify succeeded; opening the userspace TLS tunnel.")
            phase = "TLS tunnel setup"
            let tunnel = try UserspaceCoreDeviceTunnel(
              host: address.scopedIP, port: Int(outcome.listenPort),
              preSharedKey: outcome.preSharedKey, timeoutSeconds: timeoutSeconds)
            defer { tunnel.closeTunnel() }
            let rsd = tunnel.rsd(timeoutSeconds: timeoutSeconds)
            phase = "RSD identity exchange"
            let session = try rsd.open()
            guard session.peerInfo.udid == udid else {
              throw RemotePairing.Error.pairing("RSD resolved a different device")
            }
            progress("RSD opened through lwIP; device identity matched.")
            phase = "AFC service connection"
            // Exercise a second TCP stream while the RSD control stream is alive.
            let afcConnection = try rsd.startLockdownService(
              "com.apple.afc.shim.remote", peerInfo: session.peerInfo)
            var afc = AFCClient(connection: afcConnection)
            _ = try afc.listDirectory("/")
            progress("Concurrent AFC service connection succeeded.")
            if transferMiB > 0 {
              phase = "AFC transfer verification"
              let bytes = Data((0..<(transferMiB * 1024 * 1024)).map { UInt8($0 & 255) })
              let local = FileManager.default.temporaryDirectory.appendingPathComponent(
                "userspace-spike-\(UUID().uuidString).bin")
              try bytes.write(to: local, options: .atomic)
              defer { try? FileManager.default.removeItem(at: local) }
              let remote = "/PublicStaging/stupid-app/userspace-spike-\(UUID().uuidString).bin"
              try afc.makeDirectory("/PublicStaging/stupid-app", allowExisting: true)
              do {
                try afc.upload(localURL: local, remotePath: remote)
                guard try afc.readFileContents(remote) == bytes else {
                  throw USBMuxClient.Error.invalidInput("AFC transfer bytes did not match")
                }
                try afc.remove(remote, allowMissing: false)
              } catch {
                try? afc.remove(remote, allowMissing: true)
                throw error
              }
              progress(
                "Uploaded, downloaded, compared, and removed \(transferMiB) MiB through AFC.")
            }
            if let ipa, let bundleID {
              phase = "IPA staging and installation"
              let runner = NativeNetworkRunner(
                pairingDirectory: pairingDirectory, udid: udid, ipa: ipa, bundleID: bundleID,
                progress: progress)
              try runner.install(rsd: rsd, peerInfo: session.peerInfo)
              phase = "AppService launch"
              let service = try session.connect(service: AppServiceClient.serviceName)
              let pid = try AppServiceClient(service: service).launchApplication(bundleID: bundleID)
              progress("Installed, verified, and launched through lwIP (pid \(pid)).")
            }
            withExtendedLifetime(session) {}
            return
          } catch {
            var detail = RemotePairing.redact(detail: String(describing: error), udid: udid)
            for saved in identifiers {
              detail = detail.replacingOccurrences(of: saved, with: "<pairing>")
            }
            detail = detail.replacingOccurrences(of: address.scopedIP, with: "<endpoint>")
            // SocketConnection is shared with usbmux; translate its generic
            // transport errors so this proof reports the actual failing phase.
            if let socketError = error as? USBMuxClient.Error {
              switch socketError {
              case .connectionFailed(let code):
                detail =
                  "service stream failed (code \(code)); check device reachability and tunnel lifecycle"
              case .timedOut:
                detail = "service stream timed out; check device reachability and the tunnel budget"
              case .connectionClosed:
                detail = "service stream closed; check device reachability and tunnel lifecycle"
              default: break
              }
            }
            failures.append("\(phase): \(detail)")
            progress("Userspace candidate failed during \(phase): \(detail)")
          }
        }
      }
    }
    throw NativeNetworkRunner.Error.allFailed(failures.suffix(5).joined(separator: "; "))
  }
}
