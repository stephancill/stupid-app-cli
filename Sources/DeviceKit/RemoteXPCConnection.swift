import Foundation

/// A bounded RemoteXPC client speaking RemoteXPC's HTTP/2-derived framing
/// over an existing established connection.
final class RemoteXPCConnection: @unchecked Sendable {
  /// Stream identifiers used by Apple's RemoteXPC services.
  enum Stream: UInt32 {
    case root = 1
    case reply = 3
  }

  enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case transport
    case timedOut
    case connectionClosed
    case malformed(String)
    case protocolViolation(String)
    case unsupported(String)

    var description: String {
      switch self {
      case .transport:
        return "The RemoteXPC transport failed."
      case .timedOut:
        return "The RemoteXPC exchange timed out."
      case .connectionClosed:
        return "The RemoteXPC peer closed the connection."
      case .malformed(let detail):
        return "The RemoteXPC message is malformed: \(detail)."
      case .protocolViolation(let detail):
        return "The RemoteXPC peer violated the protocol: \(detail)."
      case .unsupported(let detail):
        return "The RemoteXPC request is unsupported: \(detail)."
      }
    }
  }

  private let connection: SocketConnection
  private var nextMessageID: [UInt32: UInt64] = [Stream.root.rawValue: 0, Stream.reply.rawValue: 0]
  private var previousFrameData = Data()

  init(connection: SocketConnection) {
    self.connection = connection
  }

  /// Performs the RemoteXPC handshake and blocks until the peer has sent its
  /// initial SETTINGS frame. The caller should then invoke `completeHandshake`.
  func start() throws {
    var out = Data()
    out.append(HTTP2Frame.magic)
    out.append(
      HTTP2Frame.settingsFrame(pairs: [
        (id: 0x3, value: 100),
        (id: 0x4, value: 1_048_576),
      ]))
    out.append(HTTP2Frame.windowUpdate(streamID: 0, increment: 983_041))
    out.append(HTTP2Frame.headersFrame(streamID: Stream.root.rawValue))
    // The client offers an empty request followed by a bare keep-alive wrapper.
    out.append(
      HTTP2Frame.dataFrame(
        streamID: Stream.root.rawValue, payload: try xpcEmptyDictionary(flags: 0x0000_0001)))
    out.append(
      HTTP2Frame.dataFrame(
        streamID: Stream.root.rawValue, payload: xpcEmptyWrapper(flags: 0x0000_0201)))
    nextMessageID[Stream.root.rawValue]! += 1
    out.append(HTTP2Frame.headersFrame(streamID: Stream.reply.rawValue))
    out.append(
      HTTP2Frame.dataFrame(
        streamID: Stream.reply.rawValue,
        payload: xpcEmptyWrapper(
          flags: XPCCodec.Flags.initHandshake.rawValue | XPCCodec.Flags.alwaysSet.rawValue)))
    nextMessageID[Stream.reply.rawValue]! += 1
    try connection.write(out)

    let settings = try receiveFrame()
    guard settings.kind == .settings else {
      throw Error.protocolViolation("expected a SETTINGS frame after the handshake")
    }
    if settings.flags & HTTP2Frame.Flags.ack.rawValue == 0 {
      try connection.write(HTTP2Frame.settingsAck())
    }
  }

  /// Sends one request carrying an XPC dictionary.
  func sendRequest(_ body: [String: XPCValue], wantingReply: Bool) throws {
    let flags = xpcFlags(dataPresent: !body.isEmpty, wantingReply: wantingReply)
    let wrapper = try XPCCodec.encodeWrapper(
      value: .dictionary(body),
      messageID: nextMessageID[Stream.root.rawValue]!,
      flags: flags
    )
    nextMessageID[Stream.root.rawValue]! += 1
    try connection.write(HTTP2Frame.dataFrame(streamID: Stream.root.rawValue, payload: wrapper))
  }

  /// Reads frames until a message carrying a non-empty object is decoded.
  func receiveResponse() throws -> XPCValue {
    while true {
      let frame = try receiveDataFrame()
      if frame.streamID % 2 == 0, !frame.payload.isEmpty {
        let window = frame.payload.count
        try connection.write(HTTP2Frame.windowUpdate(streamID: 0, increment: UInt32(window)))
        try connection.write(
          HTTP2Frame.windowUpdate(streamID: frame.streamID, increment: UInt32(window)))
      }
      var buffer = previousFrameData
      buffer.append(frame.payload)
      do {
        let wrapper = try XPCCodec.decodeWrapper(buffer)
        previousFrameData = Data()
        if wrapper.value == nil {
          continue
        }
        if case .dictionary(let value) = wrapper.value, value.isEmpty {
          continue
        }
        nextMessageID[frame.streamID] = wrapper.messageID + 1
        return wrapper.value!
      } catch XPCCodec.Error.truncated {
        previousFrameData = buffer
      }
    }
  }

  private func xpcEmptyDictionary(flags: UInt32) throws -> Data {
    try XPCCodec.encodeWrapper(
      value: .dictionary([:]), messageID: nextMessageID[Stream.root.rawValue]!, flags: flags)
  }

  private func xpcEmptyWrapper(flags: UInt32) -> Data {
    var out = Data()
    var magic = XPCCodec.wrapperMagic.littleEndian
    withUnsafeBytes(of: &magic) { out.append(contentsOf: $0) }
    var flagBytes = flags.littleEndian
    withUnsafeBytes(of: &flagBytes) { out.append(contentsOf: $0) }
    var zero = UInt64(0).littleEndian
    withUnsafeBytes(of: &zero) { out.append(contentsOf: $0) }
    withUnsafeBytes(of: &zero) { out.append(contentsOf: $0) }
    return out
  }

  private func receiveFrame() throws -> (
    kind: HTTP2Frame.Kind, flags: UInt8, streamID: UInt32, payload: Data
  ) {
    let header: Data
    do {
      header = try connection.read(count: 9)
    } catch {
      throw mapTransport(error)
    }
    let decoded = try HTTP2Frame.decodeHeader(header)
    let payload: Data
    do {
      payload = decoded.length > 0 ? try connection.read(count: decoded.length) : Data()
    } catch {
      throw mapTransport(error)
    }
    return (decoded.kind, decoded.flags, decoded.streamID, payload)
  }

  private func mapTransport(_ error: Swift.Error) -> Error {
    if let transport = error as? USBMuxClient.Error {
      switch transport {
      case .timedOut:
        return .timedOut
      case .connectionClosed:
        return .connectionClosed
      default:
        return .transport
      }
    }
    return .transport
  }

  private func receiveDataFrame() throws -> (streamID: UInt32, payload: Data) {
    while true {
      let frame = try receiveFrame()
      switch frame.kind {
      case .goaway:
        throw Error.connectionClosed
      case .rstStream:
        throw Error.protocolViolation("the peer reset a stream")
      case .data:
        return (frame.streamID, frame.payload)
      default:
        if frame.kind == .settings, frame.flags & HTTP2Frame.Flags.ack.rawValue == 0 {
          try connection.write(HTTP2Frame.settingsAck())
        }
        continue
      }
    }
  }

  private func xpcFlags(dataPresent: Bool, wantingReply: Bool) -> UInt32 {
    var flags = XPCCodec.Flags.alwaysSet.rawValue
    if dataPresent {
      flags |= XPCCodec.Flags.dataPresent.rawValue
    }
    if wantingReply {
      flags |= XPCCodec.Flags.wantingReply.rawValue
    }
    return flags
  }
}
