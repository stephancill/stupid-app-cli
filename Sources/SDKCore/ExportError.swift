import Foundation

/// Errors that identify the failing phase so user-facing messages stay actionable.
public enum ExportError: Error, Equatable, Sendable, CustomStringConvertible {
    case xcodeMissing(URL)
    case developerDirMissing(URL)
    case noNumericIOSSDK(String)
    case multipleNumericIOSSDKs([String])
    case hostArchUnsupported(String)
    case toolsetDownloadFailed(URL, Int)
    case toolsetChecksumMismatch(String)
    case unexpectedSymlink(String)
    case copyFailed(source: String, destination: String, reason: String)
    case swiftVersionUnparseable(String)

    public var description: String {
        switch self {
        case let .xcodeMissing(url):
            return "No Xcode.app found at '\(url.path)'."
        case let .developerDirMissing(url):
            return "Xcode does not appear to be an Xcode installation: no 'Contents/Developer' at '\(url.path)'."
        case let .noNumericIOSSDK(platform):
            return "No numeric iPhoneOS SDK found under \(platform)."
        case let .multipleNumericIOSSDKs(versions):
            return "Multiple iPhoneOS SDK versions found; refusing to pick: \(versions.joined(separator: ", "))."
        case let .hostArchUnsupported(arch):
            return "No pinned Linux darwin-tools toolset for host architecture '\(arch)'."
        case let .toolsetDownloadFailed(url, status):
            return "Downloading toolset failed with HTTP \(status) from \(url.absoluteString)."
        case let .toolsetChecksumMismatch(computed):
            return "Toolset archive SHA-256 \(computed) does not match the pinned value."
        case let .unexpectedSymlink(path):
            return "Refusing to copy an unexpected symlink at '\(path)'; the export tree is expected to be regular files and directories."
        case let .copyFailed(source, destination, reason):
            return "Failed to copy '\(source)' to '\(destination)': \(reason)"
        case let .swiftVersionUnparseable(output):
            return "Could not parse the Xcode toolchain Swift version from output: \(output)"
        }
    }
}
