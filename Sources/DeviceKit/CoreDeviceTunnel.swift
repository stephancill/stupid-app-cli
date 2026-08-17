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
    let mux = USBMuxClient(address: usbmuxAddress, timeoutSeconds: timeoutSeconds)
    guard
      let device = try mux.devices().first(where: {
        $0.connectionType == .usb && $0.serialNumber == udid
      })
    else {
      throw Error.deviceNotFound
    }
    guard let pairData = try pairRecordData(mux: mux, udid: udid) else {
      throw Error.pairRecordMissing
    }
    let pairRecord = try LockdownPairRecord(data: pairData)
    let lockdown = try mux.connectLockdown(deviceID: device.deviceID)
    _ = try lockdown.queryType()
    try lockdown.startSession(using: pairRecord)
    defer { try? lockdown.stopSession() }
    progress?("Established the native lockdown session.")

    let service = try lockdown.startService(
      "com.apple.internal.devicecompute.CoreDeviceProxy",
      pairRecord: pairRecord
    )
    let tunnelConnection = try mux.connectService(
      deviceID: device.deviceID,
      service: service,
      pairRecord: pairRecord
    )
    progress?("Connected to the CoreDevice proxy service.")

    let handshake = try performTunnelHandshake(over: tunnelConnection)
    progress?(
      "CoreDevice tunnel established (client \(handshake.clientAddress) server \(handshake.serverAddress):\(handshake.serverRSDPort))."
    )

    let tun = try createTUN(handshake: handshake)
    defer { tun.close() }
    try tun.addRoute(to: handshake.serverAddress)
    progress?("Configured the native tunnel interface.")

    let pump = PacketPump(
      tunnel: tunnelConnection,
      tun: tun,
      progress: progress
    )
    pump.start()
    defer { pump.stop() }
    progress?("Native tunnel packet pump started.")

    let rsd = RSDClient(
      host: handshake.serverAddress,
      port: handshake.serverRSDPort,
      timeoutSeconds: timeoutSeconds
    )
    progress?("Connecting RSD to \(handshake.serverAddress):\(handshake.serverRSDPort)...")
    let peerInfo: RSDClient.PeerInfo
    do {
      peerInfo = try rsd.connect()
    } catch {
      throw Error.launch("RSD connect failed: \(error)")
    }
    guard peerInfo.udid == udid else {
      throw Error.launch("the tunnel resolved a different device")
    }
    progress?("Resolved the remote service discovery peer.")

    let serviceConnection: RemoteXPCService
    do {
      serviceConnection = try rsd.connect(service: AppServiceClient.serviceName, peerInfo: peerInfo)
    } catch {
      throw Error.launch("the appservice endpoint was unavailable: \(error)")
    }
    let appService = AppServiceClient(service: serviceConnection)
    let pid = try appService.launchApplication(bundleID: bundleID)
    progress?("Launched the application (pid \(pid)).")
    return pid
  }

  private func pairRecordData(mux: USBMuxClient, udid: String) throws -> Data? {
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

  private func performTunnelHandshake(over connection: LockdownServiceConnection) throws
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
      bodyLength = try Self.bodyLength(header: header)
    } catch {
      throw error
    }
    let body = try connection.read(count: bodyLength)
    var response = header
    response.append(body)
    return try Self.handshakeResponse(from: response)
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

  private func createTUN(handshake: CoreDeviceTLSConnection.Handshake) throws -> TUNDevice {
    var output: OpaquePointer?
    let result = handshake.clientAddress.withCString {
      stupid_app_tun_create("", $0, Int32(handshake.clientMTU), &output)
    }
    guard result == STUPID_APP_TUN_OK.rawValue, let output else {
      if result == STUPID_APP_TUN_UNSUPPORTED.rawValue {
        throw Error.tunUnsupported
      }
      throw Error.tunnelSetup("TUN creation failed with public error code \(result)")
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

/// Forwards IPv6 packets between the CoreDevice tunnel socket and the TUN
/// device in both directions until stopped.
private final class PacketPump: @unchecked Sendable {
  private let tunnel: LockdownServiceConnection
  private let tun: TUNDevice
  private let progress: (@Sendable (String) -> Void)?
  private let lock = NSLock()
  private let group = DispatchGroup()
  private let queue = DispatchQueue(
    label: "stupid-app.coredevice-pump",
    attributes: .concurrent
  )
  private var started = false
  private var stopped = false

  init(tunnel: LockdownServiceConnection, tun: TUNDevice, progress: (@Sendable (String) -> Void)?) {
    self.tunnel = tunnel
    self.tun = tun
    self.progress = progress
  }

  func start() {
    lock.lock()
    guard !started else {
      lock.unlock()
      return
    }
    started = true
    lock.unlock()
    group.enter()
    queue.async {
      self.pumpTUNToTunnel()
      self.group.leave()
    }
    group.enter()
    queue.async {
      self.pumpTunnelToTUN()
      self.group.leave()
    }
  }

  func stop() {
    lock.lock()
    stopped = true
    lock.unlock()
    tun.close()
    tunnel.cancel()
    group.wait()
    tunnel.close()
  }

  private func isStopped() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }

  private func pumpTUNToTunnel() {
    var count = 0
    while !isStopped() {
      do {
        let packet = try tun.read()
        try tunnel.write(packet)
        count += 1
        if debugEnabled(), count % 5 == 0 {
          progress?("pump tun->tunnel: \(count) packets, \(packet.count)B")
        }
      } catch {
        return
      }
    }
  }

  private func pumpTunnelToTUN() {
    var count = 0
    while !isStopped() {
      do {
        let header = try tunnel.read(count: 40)
        guard header.count == 40 else { return }
        let payloadLength = (Int(header[4]) << 8) | Int(header[5])
        guard payloadLength >= 0, payloadLength <= 65_536 - 40 else { return }
        let payload = try tunnel.read(count: payloadLength)
        var packet = header
        packet.append(payload)
        try tun.write(packet)
        count += 1
        if debugEnabled(), count % 5 == 0 {
          progress?("pump tunnel->tun: \(count) packets, \(packet.count)B")
        }
      } catch {
        return
      }
    }
  }

  private func debugEnabled() -> Bool {
    ProcessInfo.processInfo.environment["STUPID_APP_TUN_DEBUG"] != nil
  }
}
