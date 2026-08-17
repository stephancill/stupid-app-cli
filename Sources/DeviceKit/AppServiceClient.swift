import Foundation

/// CoreDevice application-service client used to launch installed apps
/// through RemoteXPC.
public struct AppServiceClient: Sendable {
  public static let serviceName = "com.apple.coredevice.appservice"
  public static let launchFeature = "com.apple.coredevice.feature.launchapplication"

  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case missingOutput
    case invalidOutput(String)
    case noProcessIdentifier

    public var description: String {
      switch self {
      case .missingOutput:
        return "The launch response did not contain a CoreDevice output value."
      case .invalidOutput(let detail):
        return "The launch response output is invalid: \(detail)."
      case .noProcessIdentifier:
        return "The launch response did not contain a process identifier."
      }
    }
  }

  private let service: RemoteXPCService

  public init(service: RemoteXPCService) {
    self.service = service
  }

  /// Launches an installed application and returns the process identifier
  /// reported by the device.
  public func launchApplication(bundleID: String) throws -> Int64 {
    let output = try service.invoke(Self.launchRequest(bundleID: bundleID))
    return try Self.processIdentifier(from: output)
  }

  static func launchRequest(bundleID: String) -> [String: XPCValue] {
    [
      "CoreDevice.CoreDeviceDDIProtocolVersion": .int64(0),
      "CoreDevice.action": .dictionary([:]),
      "CoreDevice.coreDeviceVersion": .dictionary([
        "components": .array([
          .uint64(325), .uint64(3),
        ]),
        "originalComponentsCount": .int64(2),
        "stringValue": .string("325.3"),
      ]),
      "CoreDevice.deviceIdentifier": .string(UUID().uuidString.lowercased()),
      "CoreDevice.featureIdentifier": .string(Self.launchFeature),
      "CoreDevice.input": .dictionary([
        "applicationSpecifier": .dictionary([
          "bundleIdentifier": .dictionary(["_0": .string(bundleID)])
        ]),
        "options": .dictionary([
          "arguments": .array([]),
          "environmentVariables": .dictionary([:]),
          "standardIOUsesPseudoterminals": .bool(true),
          "startStopped": .bool(false),
          "terminateExisting": .bool(true),
          "user": .dictionary(["shortName": .string("mobile")]),
          "platformSpecificOptions": .data(Data([0x62, 0x70, 0x6c, 0x69, 0x73, 0x74, 0x30, 0x30])),
        ]),
        "standardIOIdentifiers": .dictionary([:]),
      ]),
      "CoreDevice.invocationIdentifier": .string(UUID().uuidString.lowercased()),
    ]
  }

  static func processIdentifier(from response: XPCValue) throws -> Int64 {
    guard let root = response.dictionaryValue, let output = root["CoreDevice.output"] else {
      throw Error.missingOutput
    }
    if let identifier = findProcessIdentifier(in: output) {
      return identifier
    }
    throw Error.noProcessIdentifier
  }

  private static func findProcessIdentifier(in value: XPCValue) -> Int64? {
    switch value {
    case .dictionary(let entries):
      if let identifier = entries["processIdentifier"]?.int64Value {
        return identifier
      }
      if let identifier = entries["pid"]?.int64Value {
        return identifier
      }
      for entry in entries.values {
        if let nested = findProcessIdentifier(in: entry) {
          return nested
        }
      }
      return nil
    case .array(let entries):
      for entry in entries {
        if let nested = findProcessIdentifier(in: entry) {
          return nested
        }
      }
      return nil
    default:
      return nil
    }
  }
}
