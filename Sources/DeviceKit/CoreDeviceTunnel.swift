import CTUN
import Foundation

/// Native CoreDevice proxy tunnel over a lockdown session, used to launch
/// applications over USB. Owns the CDTunnel handshake, the privileged TUN
/// interface, the packet pump, and the RSD/AppService launch.
public struct CoreDeviceUSBLauncher: Sendable {
  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case deviceNotFound
    case pairRecordMissing
    case serviceStartFailed(String)
    case tunnelSetup(String)
    case handshakeFailed(String)
    case tunUnsupported
    case tunnelClosed
    case launch(String)

    public var description: String {
      switch self {
      case .deviceNotFound:
        return "The selected USB device is not available through usbmuxd."
      case .pairRecordMissing:
        return "No trusted usbmux pair record exists for the selected device. Pair it first."
      case .serviceStartFailed(let detail):
        return "Could not start the CoreDevice proxy service: \(detail)."
      case .tunnelSetup(let detail):
        return "CoreDevice tunnel setup failed: \(detail)."
      case .handshakeFailed(let detail):
        return "The CoreDevice tunnel handshake failed: \(detail)."
      case .tunUnsupported:
        return "Native CoreDevice tunneling requires a Linux TUN device."
      case .tunnelClosed:
        return "The CoreDevice tunnel closed before the launch completed."
      case .launch(let detail):
        return "Application launch failed: \(detail)."
      }
    }
  }

  public var usbmuxAddress: String?
  public var pairingDirectory: URL?
  public var timeoutSeconds: Double
  public var progress: (@Sendable (String) -> Void)?

  public init(
    usbmuxAddress: String? = nil,
    pairingDirectory: URL? = nil,
    timeoutSeconds: Double = 60,
    progress: (@Sendable (String) -> Void)? = nil
  ) {
    self.usbmuxAddress = usbmuxAddress
    self.pairingDirectory = pairingDirectory
    self.timeoutSeconds = timeoutSeconds
    self.progress = progress
  }

  /// Launches an installed application over a native CoreDevice proxy tunnel
  /// and returns the process identifier reported by the device.
  public func launch(bundleID: String, udid: String) throws -> Int64 {
    guard !bundleID.isEmpty, !udid.isEmpty else {
      throw Error.launch("bundle identifier and device identifier are required")
    }
    let tunnel = try USBCoreDeviceTunnel(
      usbmuxAddress: usbmuxAddress,
      pairingDirectory: pairingDirectory,
      timeoutSeconds: timeoutSeconds,
      udid: udid,
      progress: progress
    )
    defer { tunnel.close() }

    let serviceConnection: RemoteXPCService
    do {
      serviceConnection = try tunnel.session.connect(service: AppServiceClient.serviceName)
    } catch {
      throw Error.launch("the appservice endpoint was unavailable: \(error)")
    }
    let appService = AppServiceClient(service: serviceConnection)
    let pid = try appService.launchApplication(bundleID: bundleID)
    progress?("Launched the application (pid \(pid)).")
    return pid
  }

  /// Validates the CDTunnel response header and returns the JSON body length.
  static func bodyLength(header: Data) throws -> Int {
    guard header.count == 10, header.prefix(8) == Data("CDTunnel".utf8) else {
      throw Error.handshakeFailed("invalid CDTunnel response header")
    }
    let bodyLength = (Int(header[8]) << 8) | Int(header[9])
    guard bodyLength > 0, bodyLength <= 16_384 else {
      throw Error.handshakeFailed("invalid CDTunnel response length")
    }
    return bodyLength
  }

  /// Decodes a complete CDTunnel response frame into a handshake.
  static func handshakeResponse(from data: Data) throws -> CoreDeviceTLSConnection.Handshake {
    let bodyLength = try bodyLength(header: Data(data.prefix(10)))
    guard data.count == 10 + bodyLength else {
      throw Error.handshakeFailed("CDTunnel response is truncated")
    }
    do {
      return try CoreDeviceTLSConnection.decode(data)
    } catch {
      throw Error.handshakeFailed(String(describing: error))
    }
  }
}

/// An established native CoreDevice USB tunnel with its TUN interface, packet
/// relay, and RSD session. Creating it owns the lockdown session, the
/// CoreDevice proxy service tunnel, the CDTunnel handshake, the privileged TUN
/// device, the relay thread, and the verified RSD session. `close()` tears the
/// stack down in the reverse order so neither the relay nor the RSD control
/// connection is cut before its dependents.
public final class USBCoreDeviceTunnel: @unchecked Sendable {
  private let lockdown: LockdownClient
  private let tunnelConnection: LockdownServiceConnection
  private let tun: TUNDevice
  private let relay: TunnelRelay

  public let session: RSDSession

  public init(
    usbmuxAddress: String?,
    pairingDirectory: URL?,
    timeoutSeconds: Double,
    udid: String,
    progress: (@Sendable (String) -> Void)?
  ) throws {
    let mux = USBMuxClient(address: usbmuxAddress, timeoutSeconds: timeoutSeconds)
    guard
      let device = try mux.devices().first(where: {
        $0.connectionType == .usb && $0.serialNumber == udid
      })
    else {
      throw CoreDeviceUSBLauncher.Error.deviceNotFound
    }
    guard
      let pairData = try Self.pairRecordData(
        mux: mux, pairingDirectory: pairingDirectory, udid: udid)
    else {
      throw CoreDeviceUSBLauncher.Error.pairRecordMissing
    }
    let pairRecord = try LockdownPairRecord(data: pairData)
    let lockdown = try mux.connectLockdown(deviceID: device.deviceID)
    _ = try lockdown.queryType()
    try lockdown.startSession(using: pairRecord)
    progress?("Established the native lockdown session.")

    var tunnelConnection: LockdownServiceConnection?
    var tun: TUNDevice?
    var relay: TunnelRelay?
    var completed = false
    defer {
      if !completed {
        relay?.stop()
        if let tunnelConnection {
          tunnelConnection.cancel()
          tunnelConnection.close()
        }
        tun?.close()
        try? lockdown.stopSession()
      }
    }

    let service = try lockdown.startService(
      "com.apple.internal.devicecompute.CoreDeviceProxy",
      pairRecord: pairRecord
    )
    let tunnel = try mux.connectService(
      deviceID: device.deviceID,
      service: service,
      pairRecord: pairRecord
    )
    tunnelConnection = tunnel
    progress?("Connected to the CoreDevice proxy service.")

    let handshake = try Self.performTunnelHandshake(over: tunnel)
    progress?(
      "CoreDevice tunnel established (client \(handshake.clientAddress) server \(handshake.serverAddress):\(handshake.serverRSDPort))."
    )

    let tunDevice = try Self.createTUN(handshake: handshake)
    tun = tunDevice
    try tunDevice.addRoute(to: handshake.serverAddress)
    progress?("Configured the native tunnel interface.")

    let tunDescriptor = try tunDevice.descriptor()
    let tunnelRelay = TunnelRelay(tunnel: tunnel, tunDescriptor: tunDescriptor)
    tunnelRelay.start()
    relay = tunnelRelay
    progress?("Native tunnel relay started.")

    let rsd = RSDClient(
      host: handshake.serverAddress,
      port: handshake.serverRSDPort,
      timeoutSeconds: timeoutSeconds
    )
    progress?("Connecting RSD to \(handshake.serverAddress):\(handshake.serverRSDPort)...")
    let openedSession: RSDSession
    do {
      openedSession = try rsd.open()
    } catch {
      throw CoreDeviceUSBLauncher.Error.launch("RSD connect failed: \(error)")
    }
    guard openedSession.peerInfo.udid == udid else {
      throw CoreDeviceUSBLauncher.Error.launch("the tunnel resolved a different device")
    }
    progress?("Resolved the remote service discovery peer.")

    completed = true
    self.lockdown = lockdown
    self.tunnelConnection = tunnel
    self.tun = tunDevice
    self.relay = tunnelRelay
    self.session = openedSession
  }

  /// Tears the tunnel, relay, TUN, and lockdown session down in the reverse
  /// order of creation. Idempotent once the stack is fully constructed.
  public func close() {
    relay.stop()
    tunnelConnection.cancel()
    tunnelConnection.close()
    tun.close()
    try? lockdown.stopSession()
  }

  private static func pairRecordData(
    mux: USBMuxClient,
    pairingDirectory: URL?,
    udid: String
  ) throws -> Data? {
    if let pairingDirectory {
      guard !udid.contains("/"), !udid.contains("..") else {
        throw USBMuxClient.Error.invalidInput("device identifier is not a safe file name")
      }
      let local = pairingDirectory.appendingPathComponent("\(udid).plist")
      if FileManager.default.fileExists(atPath: local.path) {
        return try Data(contentsOf: local)
      }
    }
    return try mux.readPairRecord(identifier: udid)
  }

  private static func performTunnelHandshake(over connection: LockdownServiceConnection) throws
    -> CoreDeviceTLSConnection.Handshake
  {
    let request = try CoreDeviceTLSConnection.frame([
      "mtu": 16_000,
      "type": "clientHandshakeRequest",
    ])
    try connection.write(request)
    let header = try connection.read(count: 10)
    let bodyLength: Int
    do {
      bodyLength = try CoreDeviceUSBLauncher.bodyLength(header: header)
    } catch {
      throw error
    }
    let body = try connection.read(count: bodyLength)
    var response = header
    response.append(body)
    return try CoreDeviceUSBLauncher.handshakeResponse(from: response)
  }

  private static func createTUN(handshake: CoreDeviceTLSConnection.Handshake) throws -> TUNDevice {
    var output: OpaquePointer?
    let result = handshake.clientAddress.withCString {
      stupid_app_tun_create("", $0, Int32(handshake.clientMTU), &output)
    }
    guard result == STUPID_APP_TUN_OK.rawValue, let output else {
      if result == STUPID_APP_TUN_UNSUPPORTED.rawValue {
        throw CoreDeviceUSBLauncher.Error.tunUnsupported
      }
      throw CoreDeviceUSBLauncher.Error.tunnelSetup(
        "TUN creation failed with public error code \(result)")
    }
    return TUNDevice(handle: output)
  }
}

/// Owns a TUN device handle and provides bounded packet read/write. Closing is
/// idempotent: the underlying handle is destroyed exactly once.
public final class TUNDevice: @unchecked Sendable {
  private let lock = NSLock()
  private var handle: OpaquePointer?

  init(handle: OpaquePointer) {
    self.handle = handle
  }

  deinit {
    destroy()
  }

  var name: String {
    guard let current = handleOrNil else { return "" }
    var buffer = [CChar](repeating: 0, count: 16)
    _ = stupid_app_tun_name(current, &buffer, buffer.count)
    let bytes = buffer.map { UInt8(bitPattern: $0) }
    guard let terminator = bytes.firstIndex(of: 0) else { return "" }
    return String(decoding: bytes.prefix(terminator), as: UTF8.self)
  }

  func read() throws -> Data {
    guard let handle = handleOrNil else {
      throw CoreDeviceUSBLauncher.Error.tunnelClosed
    }
    var buffer = [UInt8](repeating: 0, count: 65_536)
    let capacity = buffer.count
    let result = buffer.withUnsafeMutableBytes {
      stupid_app_tun_read(handle, $0.bindMemory(to: UInt8.self).baseAddress, capacity)
    }
    guard result > 0 else {
      throw CoreDeviceUSBLauncher.Error.tunnelClosed
    }
    return Data(buffer.prefix(Int(result)))
  }

  func write(_ data: Data) throws {
    guard let handle = handleOrNil else {
      throw CoreDeviceUSBLauncher.Error.tunnelClosed
    }
    let result = data.withUnsafeBytes {
      stupid_app_tun_write(handle, $0.bindMemory(to: UInt8.self).baseAddress, data.count)
    }
    guard result == STUPID_APP_TUN_OK.rawValue else {
      throw CoreDeviceUSBLauncher.Error.tunnelClosed
    }
  }

  func addRoute(to destination: String) throws {
    guard let handle = handleOrNil else {
      throw CoreDeviceUSBLauncher.Error.tunnelClosed
    }
    let result = destination.withCString {
      stupid_app_tun_add_route(handle, $0)
    }
    guard result == STUPID_APP_TUN_OK.rawValue else {
      throw CoreDeviceUSBLauncher.Error.tunnelSetup(
        "route to \(destination) could not be installed")
    }
  }

  func descriptor() throws -> Int32 {
    guard let current = handleOrNil else {
      throw CoreDeviceUSBLauncher.Error.tunnelClosed
    }
    var descriptor: Int32 = -1
    let result = stupid_app_tun_fd(current, &descriptor)
    guard result == STUPID_APP_TUN_OK.rawValue, descriptor >= 0 else {
      throw CoreDeviceUSBLauncher.Error.tunnelSetup("TUN descriptor could not be read")
    }
    return descriptor
  }

  func close() {
    destroy()
  }

  private var handleOrNil: OpaquePointer? {
    lock.lock()
    defer { lock.unlock() }
    return handle
  }

  private func destroy() {
    lock.lock()
    let current = handle
    handle = nil
    lock.unlock()
    if let current {
      stupid_app_tun_destroy(current)
    }
  }
}

/// Runs the single-threaded non-blocking relay between the TLS CoreDevice
/// tunnel connection and the TUN device. OpenSSL forbids concurrent
/// SSL_read/SSL_write on one connection, so the relay services both directions
/// from a single thread by polling the descriptors.
private final class TunnelRelay: @unchecked Sendable {
  private let tunnel: LockdownServiceConnection
  private let tunDescriptor: Int32
  private let lock = NSLock()
  private let group = DispatchGroup()
  private let queue = DispatchQueue(label: "stupid-app.coredevice-relay")
  private let stopFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
  private var started = false
  private var stopped = false

  init(tunnel: LockdownServiceConnection, tunDescriptor: Int32) {
    self.tunnel = tunnel
    self.tunDescriptor = tunDescriptor
    stopFlag.pointee = 0
  }

  deinit {
    stopFlag.deallocate()
  }

  func start() {
    lock.lock()
    defer { lock.unlock() }
    guard !started else { return }
    started = true
    group.enter()
    queue.async { [self] in
      _ = tunnel.relay(to: tunDescriptor, stop: stopFlag)
      group.leave()
    }
  }

  func stop() {
    lock.lock()
    guard !stopped else {
      lock.unlock()
      return
    }
    stopped = true
    lock.unlock()
    stopFlag.pointee = 1
    tunnel.cancel()
    group.wait()
  }
}
