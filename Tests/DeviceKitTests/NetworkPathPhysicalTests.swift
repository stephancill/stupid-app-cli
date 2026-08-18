import Foundation
import Testing

@testable import DeviceKit

/// Physical network-path debug gate. Skips unless
/// `STUPID_APP_PHYSICAL_PAIRING_DIR` (and optionally `STUPID_APP_PHYSICAL_UDID`)
/// are set. Drives mDNS discovery, Pair-Verify, the persistent tunnel, and the
/// RSD open so the network transport can be iterated on without rebuilding the
/// acceptance app.
struct NetworkPathPhysicalTests {
  @Test("establishes the native network tunnel and opens RSD")
  func networkPath() throws {
    let environment = ProcessInfo.processInfo.environment
    let timeout = Double(environment["STUPID_APP_PHYSICAL_TIMEOUT"] ?? "6") ?? 6
    if let endpoint = environment["STUPID_APP_PHYSICAL_RSD_ENDPOINT"] {
      let separator = endpoint.lastIndex(of: ":")!
      let host = String(endpoint[..<separator])
      let port = Int(endpoint[endpoint.index(after: separator)...])!
      print("[phys] connecting native RSD to \(host):\(port)")
      let rsd = RSDClient(host: host, port: port, timeoutSeconds: timeout)
      let session = try rsd.open()
      print(
        "[phys] NATIVE RSD OPENED udid=\(session.peerInfo.udid) services=\(session.peerInfo.services.keys.sorted())"
      )
      return
    }
    guard let pairingDir = environment["STUPID_APP_PHYSICAL_PAIRING_DIR"] else { return }
    let udid = environment["STUPID_APP_PHYSICAL_UDID"] ?? "00008130-001C4CA030A1401C"

    let pairingDirectory = URL(fileURLWithPath: pairingDir, isDirectory: true)
    let identifiers = try RemotePairing.pairedIdentifiers(in: pairingDirectory)
    print("[phys] identifiers: \(identifiers)")
    guard let identifier = identifiers.first else {
      throw RemotePairing.Error.invalidRecord("no remote record present")
    }
    let recordURL = RemotePairing.recordURL(identifier: identifier, in: pairingDirectory)
    let record = try RemotePairing.Record.load(from: recordURL)

    print("[phys] browsing mDNS for \(timeout)s...")
    let advertisements = try RemotepairingDiscovery().browse(timeout: timeout)
    print("[phys] advertisements: \(advertisements.count)")
    for advertisement in advertisements {
      print(
        "[phys]   \(advertisement.instance) ports=\(advertisement.port.map(String.init) ?? "-") addrs=\(advertisement.addresses.map(\.scopedIP))"
      )
    }

    var attempted = 0
    for advertisement in advertisements {
      guard let port = advertisement.port else { continue }
      for address in advertisement.addresses.sorted() {
        attempted += 1
        if attempted > 3 { break }
        print("[phys] trying \(address.scopedIP):\(port)")
        do {
          let client = RemotePairingTunnelClient(
            host: address.scopedIP, port: UInt16(port), timeoutSeconds: timeout)
          let outcome = try client.establish(record: record)
          print("[phys] pair-verify ok, listener \(outcome.listenPort)")

          let tunnel = try PersistentCoreDeviceTunnel(
            host: address.scopedIP,
            port: Int(outcome.listenPort),
            preSharedKey: outcome.preSharedKey,
            timeoutSeconds: 30)
          let relay = try tunnel.startRelay()
          print(
            "[phys] tunnel client=\(tunnel.handshake.clientAddress) server=\(tunnel.handshake.serverAddress):\(tunnel.handshake.serverRSDPort)"
          )
          defer {
            relay.stop()
            tunnel.stop()
          }

          if ProcessInfo.processInfo.environment["STUPID_APP_PHYSICAL_NO_RSD"] != nil {
            print("[phys] holding the tunnel idle for 5s without RSD...")
            Thread.sleep(forTimeInterval: 5)
            print("[phys] tunnel held; relay still running?")
            return
          }
          if let endpointFile = ProcessInfo.processInfo.environment[
            "STUPID_APP_PHYSICAL_ENDPOINT_FILE"]
          {
            let endpoint = "\(tunnel.handshake.serverAddress):\(tunnel.handshake.serverRSDPort)"
            try endpoint.write(
              to: URL(fileURLWithPath: endpointFile), atomically: true, encoding: .utf8)
            print("[phys] tunnel endpoint written: \(endpoint); holding 30s...")
            Thread.sleep(forTimeInterval: 30)
            return
          }
          if let delayText = ProcessInfo.processInfo.environment["STUPID_APP_PHYSICAL_RSD_DELAY"],
            let delay = Double(delayText)
          {
            print("[phys] delaying RSD connect by \(delay)s...")
            Thread.sleep(forTimeInterval: delay)
          }
          let rsd = RSDClient(
            host: tunnel.handshake.serverAddress,
            port: tunnel.handshake.serverRSDPort,
            timeoutSeconds: timeout)
          let session = try rsd.open()
          print(
            "[phys] RSD OPENED udid=\(session.peerInfo.udid) services=\(session.peerInfo.services.keys.sorted())"
          )
          return
        } catch {
          print("[phys] candidate \(attempted) failed: \(error)")
        }
      }
      if attempted >= 3 { break }
    }
    throw RemotePairing.Error.pairing("no network candidate reached the device")
  }
}
