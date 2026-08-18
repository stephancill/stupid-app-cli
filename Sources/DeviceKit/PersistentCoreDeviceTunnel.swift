import CCoreDeviceTLS
import CTUN
import Foundation

/// A persistent CoreDevice remote-pairing TCP tunnel. It retains the live
/// OpenSSL PSK connection and relays IPv6 packets to a TUN interface so RSD,
/// installation, and launch can run over the network path.
public final class PersistentCoreDeviceTunnel: @unchecked Sendable {
  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidInput(String)
    case connect(Int32)
    case tun(String)
    case relay(Int32)

    public var description: String {
      switch self {
      case .invalidInput(let detail):
        return "CoreDevice tunnel input is invalid: \(detail)."
      case .connect(let code):
        return "CoreDevice tunnel connect failed with public error code \(code)."
      case .tun(let detail):
        return "CoreDevice tunnel TUN failed: \(detail)."
      case .relay(let code):
        return "CoreDevice tunnel relay failed with public error code \(code)."
      }
    }
  }

  private let handle: OpaquePointer
  private let stopFlag: UnsafeMutablePointer<Int32>
  private let queue = DispatchQueue(label: "stupid-app.coredevice-network-relay")
  private let lock = NSLock()
  private var relayStarted = false
  private var relayStopped = false

  public let handshake: CoreDeviceTLSConnection.Handshake
  public let tun: TUNDevice

  public init(host: String, port: Int, preSharedKey: Data, timeoutSeconds: Double) throws {
    guard !host.isEmpty, (1...65_535).contains(port), !preSharedKey.isEmpty,
      preSharedKey.count <= 256,
      timeoutSeconds > 0, timeoutSeconds * 1_000 <= Double(Int32.max)
    else {
      throw Error.invalidInput("host, port, key, and timeout are invalid")
    }
    let timeoutMilliseconds = Int32(timeoutSeconds * 1_000)
    stopFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    stopFlag.initialize(to: 0)

    var output: OpaquePointer?
    var response = Data(count: 10 + 16_384)
    let responseCapacity = response.count
    var responseLength = 0
    let result = host.withCString { hostPointer in
      preSharedKey.withUnsafeBytes { keyPointer in
        response.withUnsafeMutableBytes { responsePointer in
          stupid_app_coredevice_tls_tunnel_connect(
            hostPointer,
            UInt16(port),
            keyPointer.bindMemory(to: UInt8.self).baseAddress,
            preSharedKey.count,
            timeoutMilliseconds,
            responsePointer.bindMemory(to: UInt8.self).baseAddress,
            responseCapacity,
            &responseLength,
            &output
          )
        }
      }
    }
    guard result == 0, let output else {
      stopFlag.deallocate()
      throw Error.connect(result)
    }
    handle = output
    response.removeSubrange(responseLength..<response.count)
    do {
      handshake = try CoreDeviceTLSConnection.decode(response)
    } catch {
      stopFlag.deallocate()
      stupid_app_coredevice_tls_tunnel_destroy(handle)
      throw Error.invalidInput(String(describing: error))
    }

    tun = try Self.makeTUN(handshake: handshake)
    try tun.addRoute(to: handshake.serverAddress)
  }

  deinit {
    stop()
    stupid_app_coredevice_tls_tunnel_destroy(handle)
    tun.close()
    stopFlag.deallocate()
  }

  /// Starts the blocking IPv6 packet pump on a background thread. Returns the
  /// TUN descriptor and a closure that stops the relay.
  public func startRelay() throws -> (tunDescriptor: Int32, stop: @Sendable () -> Void) {
    lock.lock()
    guard !relayStarted else {
      lock.unlock()
      throw Error.invalidInput("the relay is already running")
    }
    relayStarted = true
    lock.unlock()

    let descriptor = try tun.descriptor()
    let tunnelHandle = handle
    let stopPointer = stopFlag
    queue.async {
      _ = stupid_app_coredevice_tls_tunnel_relay(tunnelHandle, descriptor, stopPointer)
    }
    return (tunDescriptor: descriptor, stop: { [self] in stopRelay() })
  }

  private func stopRelay() {
    lock.lock()
    guard !relayStopped else {
      lock.unlock()
      return
    }
    relayStopped = true
    lock.unlock()
    stopFlag.pointee = 1
    stupid_app_coredevice_tls_tunnel_cancel(handle)
  }

  /// Stops and joins the relay thread.
  public func stop() {
    stopRelay()
    queue.sync {}
  }

  private static func makeTUN(handshake: CoreDeviceTLSConnection.Handshake) throws -> TUNDevice {
    var output: OpaquePointer?
    let result = handshake.clientAddress.withCString {
      stupid_app_tun_create("", $0, Int32(handshake.clientMTU), &output)
    }
    guard result == STUPID_APP_TUN_OK.rawValue, let output else {
      throw Error.tun("TUN creation failed with public error code \(result)")
    }
    return TUNDevice(handle: output)
  }
}
