import ASCKit
import ArgumentParser
import Foundation
import ProjectCore
import SigningKit

/// `stupid-app signing fetch`: downloads the distribution certificate and the current
/// App Store profiles for a project's bundles. It only reads: certificates and profiles
/// are created by `signing setup`. Used on hosts that sign through a release session
/// (`STUPID_APP_RELEASE_SESSION`), which have no App Store Connect key or signing key.
struct SigningFetchCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "fetch",
    abstract: "Download the distribution certificate and App Store profiles (read-only)."
  )

  @Option(
    name: .customLong("bundle-id"),
    help: "Exact bundle identifier (repeatable; defaults to the app and extensions in stupid-app.yml).")
  var bundleIDs: [String] = []

  @Option(
    name: .customLong("certificate-id"),
    help: "Distribution certificate resource ID (defaults to the release session's, then the stored one).")
  var certificateID: String?

  @Option(name: .customLong("home"), help: "Credential store directory.")
  var home: String?

  enum Error: Swift.Error, CustomStringConvertible {
    case noBundles
    case noCertificateID
    case noUsableProfile(bundleID: String, certificateID: String)
    case unknownBundleID(String)

    var description: String {
      switch self {
      case .noBundles:
        return "No bundle IDs: pass --bundle-id or run from a directory with stupid-app.yml."
      case .noCertificateID:
        return "No distribution certificate ID: pass --certificate-id, use a release session, or run `stupid-app signing setup --kind distribution`."
      case .noUsableProfile(let bundleID, let certificateID):
        return "No active, unexpired App Store profile for '\(bundleID)' includes distribution certificate \(certificateID). Run `stupid-app signing setup --kind distribution --bundle-id \(bundleID)` where the App Store Connect key is available, then fetch again."
      case .unknownBundleID(let bundleID):
        return "Bundle ID '\(bundleID)' is not registered in App Store Connect. Run `stupid-app signing setup --kind distribution --bundle-id \(bundleID)` first."
      }
    }
  }

  mutating func run() async throws {
    let context = try ASCContext.resolve(home: home, purpose: "signing fetch")
    let operations = context.operations()
    let bundles = try resolveBundleIDs()
    guard !bundles.isEmpty else { throw Error.noBundles }

    let identityManager = IdentityManager(store: context.credentialStore)
    guard
      let certificateID = certificateID ?? context.releaseSession?.info.distributionCertificateId
        ?? (try? identityManager.loadDistribution().certificateID) ?? nil
    else { throw Error.noCertificateID }

    let certificate = try operations.getCertificate(id: certificateID)
    guard let certificateDER = Data(base64Encoded: certificate.certificateContentBase64) else {
      throw ASCError.malformedPayload("certificate base64")
    }
    let certificatePEM =
      "-----BEGIN CERTIFICATE-----\n"
      + certificateDER.base64EncodedString(options: [.lineLength64Characters])
      + "\n-----END CERTIFICATE-----\n"
    try identityManager.storeDistributionCertificate(
      certificatePEM: certificatePEM, certificateID: certificateID, teamID: context.teamID)
    print("Stored distribution certificate \(certificateID)")

    for bundleID in bundles {
      guard let resourceID = try operations.findBundleID(identifier: bundleID) else {
        throw Error.unknownBundleID(bundleID)
      }
      let profiles = try operations.listBundleIDProfiles(bundleIDResourceID: resourceID)
      guard
        let content = ProfileStore.selectAppStoreProfile(
          profiles, certificateDER: certificateDER, now: Date())
      else {
        throw Error.noUsableProfile(bundleID: bundleID, certificateID: certificateID)
      }
      let url = try ProfileStore.store(
        content, home: context.homeURL, kind: .distribution, bundleID: bundleID)
      print("Stored App Store profile for \(bundleID) at \(url.path)")
    }
  }

  private func resolveBundleIDs() throws -> [String] {
    if !bundleIDs.isEmpty { return bundleIDs }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: "stupid-app.yml")) else { return [] }
    let config = try AppConfig.decode(data)
    return [config.bundleID] + (config.extensions ?? []).map(\.bundleID)
  }
}
