import CCoreDeviceTLS
import Foundation

/// A bounded, cancellable TLS-PSK exchange with an existing CoreDevice TCP listener.
public struct CoreDeviceTLSConnection: Sendable {
  public static let tlsVersion = "TLSv1.2"
  public static let cipherSuite = "PSK-AES128-GCM-SHA256"
  private static let magic = Data("CDTunnel".utf8)
  private static let maximumBodyBytes = 16_384

  public struct Handshake: Equatable, Sendable {
    public var clientAddress: String
    public var clientMTU: Int
    public var serverAddress: String
    public var serverRSDPort: Int
  }

  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidInput(String)
    case transport(Int32)
    case timedOut
    case cancelled
    case invalidResponse(String)

    public var description: String {
      switch self {
      case .invalidInput(let detail):
        return "Native CoreDevice connection input is invalid: \(detail)."
      case .transport(let code):
        return "Native CoreDevice TLS exchange failed with public error code \(code)."
      case .timedOut:
        return
          "Native CoreDevice TLS exchange timed out. Confirm the listener is reachable and retry."
      case .cancelled:
        return "Native CoreDevice TLS exchange was cancelled."
      case .invalidResponse(let detail):
        return "Native CoreDevice handshake response is invalid: \(detail)."
      }
    }
  }

  public var timeoutMilliseconds: Int32

  public init(timeoutMilliseconds: Int32 = 15_000) {
    self.timeoutMilliseconds = timeoutMilliseconds
  }

  public static func validateOpenSSL() throws {
    let result = stupid_app_coredevice_tls_validate_openssl()
    guard result == STUPID_APP_COREDEVICE_TLS_OK.rawValue else {
      throw Error.transport(result)
    }
  }

  public func connect(host: String, port: Int, preSharedKey: Data) async throws -> Handshake {
    guard !host.isEmpty else { throw Error.invalidInput("numeric host is empty") }
    guard (1...65_535).contains(port) else {
      throw Error.invalidInput("port is outside 1...65535")
    }
    guard !preSharedKey.isEmpty, preSharedKey.count <= 256 else {
      throw Error.invalidInput("PSK length is outside 1...256 bytes")
    }
    guard timeoutMilliseconds > 0 else { throw Error.invalidInput("timeout must be positive") }

    let request = try Self.frame(["mtu": 16_000, "type": "clientHandshakeRequest"])
    let operation = try Operation(
      host: host,
      port: port,
      preSharedKey: preSharedKey,
      timeoutMilliseconds: timeoutMilliseconds
    )
    let response = try await withTaskCancellationHandler {
      try await operation.start(request: request, responseCapacity: 10 + Self.maximumBodyBytes)
    } onCancel: {
      operation.cancel()
    }
    try Task.checkCancellation()
    return try Self.decode(response)
  }

  static func frame(_ object: [String: Any]) throws -> Data {
    let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard body.count <= maximumBodyBytes else {
      throw Error.invalidInput("CDTunnel body exceeds 16 KiB")
    }
    var data = magic
    data.append(UInt8(body.count >> 8))
    data.append(UInt8(body.count & 0xff))
    data.append(body)
    return data
  }

  static func decode(_ data: Data) throws -> Handshake {
    guard data.count >= 10, data.prefix(8) == magic else {
      throw Error.invalidResponse("invalid CDTunnel header")
    }
    let bodyLength = (Int(data[8]) << 8) | Int(data[9])
    guard bodyLength <= maximumBodyBytes, data.count == 10 + bodyLength else {
      throw Error.invalidResponse("invalid CDTunnel body length")
    }
    guard
      let object = try JSONSerialization.jsonObject(with: data.dropFirst(10)) as? [String: Any],
      let client = object["clientParameters"] as? [String: Any],
      let clientAddress = client["address"] as? String,
      let clientMTU = client["mtu"] as? Int,
      let serverAddress = object["serverAddress"] as? String,
      let serverRSDPort = object["serverRSDPort"] as? Int,
      !clientAddress.isEmpty,
      !serverAddress.isEmpty,
      (1...maximumBodyBytes).contains(clientMTU),
      (1...65_535).contains(serverRSDPort)
    else {
      throw Error.invalidResponse("unexpected CDTunnel response shape")
    }
    return Handshake(
      clientAddress: clientAddress,
      clientMTU: clientMTU,
      serverAddress: serverAddress,
      serverRSDPort: serverRSDPort
    )
  }
}

private final class Operation: @unchecked Sendable {
  private let connection: OpaquePointer

  init(host: String, port: Int, preSharedKey: Data, timeoutMilliseconds: Int32) throws {
    var output: OpaquePointer?
    let result = host.withCString { hostPointer in
      preSharedKey.withUnsafeBytes { keyPointer in
        stupid_app_coredevice_tls_create(
          hostPointer,
          UInt16(port),
          keyPointer.bindMemory(to: UInt8.self).baseAddress,
          preSharedKey.count,
          timeoutMilliseconds,
          &output
        )
      }
    }
    guard result == STUPID_APP_COREDEVICE_TLS_OK.rawValue, let output else {
      throw CoreDeviceTLSConnection.Error.transport(result)
    }
    connection = output
  }

  deinit {
    stupid_app_coredevice_tls_destroy(connection)
  }

  func start(request: Data, responseCapacity: Int) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async { [self] in
        var response = Data(count: responseCapacity)
        let capacity = response.count
        var responseLength = 0
        let result = request.withUnsafeBytes { requestPointer in
          response.withUnsafeMutableBytes { responsePointer in
            stupid_app_coredevice_tls_start(
              connection,
              requestPointer.bindMemory(to: UInt8.self).baseAddress,
              request.count,
              responsePointer.bindMemory(to: UInt8.self).baseAddress,
              capacity,
              &responseLength
            )
          }
        }
        if result == STUPID_APP_COREDEVICE_TLS_OK.rawValue {
          response.removeSubrange(responseLength..<response.count)
          continuation.resume(returning: response)
        } else if result == STUPID_APP_COREDEVICE_TLS_TIMED_OUT.rawValue {
          continuation.resume(throwing: CoreDeviceTLSConnection.Error.timedOut)
        } else if result == STUPID_APP_COREDEVICE_TLS_CANCELLED.rawValue {
          continuation.resume(throwing: CoreDeviceTLSConnection.Error.cancelled)
        } else {
          continuation.resume(throwing: CoreDeviceTLSConnection.Error.transport(result))
        }
      }
    }
  }

  func cancel() {
    stupid_app_coredevice_tls_cancel(connection)
  }
}
