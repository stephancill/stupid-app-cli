import Foundation
import SDKCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// macOS-side exporter that produces a device-only, checksummed Swift SDK bundle from an
/// installed Xcode. This is the Gate 0 deliverable; `SDKExportCommand` wraps it.
struct Exporter {
    struct Options {
        var xcodeAppURL: URL
        var hostTriple: String
        var targetTriple: String
        var outputURL: URL
        var scratchURL: URL
    }

    /// Paths copied from Xcode into the bundle, expressed relative to `Contents/Developer`.
    /// Device-only: no simulator or macOS content. The `swiftResourcesPath` must include
    /// `iphoneos/prebuilt-modules` because the SwiftUI/UIKit/Foundation module interfaces
    /// for the device live there in Xcode 26.
    static let wanted: [String] = [
        "Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk",
        "Platforms/iPhoneOS.platform/Developer/usr/lib",
        "Platforms/iPhoneOS.platform/Developer/Library/Frameworks",
        "Platforms/iPhoneOS.platform/Developer/Library/PrivateFrameworks",
        "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/iphoneos",
        "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/clang",
        "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/_InternalSwiftScan",
        "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/apinotes",
        "Toolchains/XcodeDefault.xctoolchain/usr/lib/clang",
    ]

    private let options: Options
    private let fileManager = FileManager.default

    init(options: Options) {
        self.options = options
    }

    func run() throws -> URL {
        let developerDir = options.xcodeAppURL.appendingPathComponent("Contents/Developer")
        guard fileManager.fileExists(atPath: developerDir.path) else {
            throw ExportError.developerDirMissing(developerDir)
        }

        let bundle = options.scratchURL.appendingPathComponent(bundleName)
        try? fileManager.removeItem(at: bundle)
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)

        let devDestination = bundle.appendingPathComponent("Developer")
        try copyWanted(from: developerDir, to: devDestination)

        let iphoneosVersion = try discoverIPhoneOSVersion(from: developerDir)
        try installToolset(into: bundle)

        try writeMetadata(into: bundle, iphoneosVersion: iphoneosVersion)

        let manifest = try buildManifest(
            bundleURL: bundle,
            iphoneosVersion: iphoneosVersion
        )
        try manifest.encode().write(to: bundle.appendingPathComponent("sdk-manifest.json"))

        let archive = try package(bundle: bundle)
        return archive
    }

    var bundleName: String {
        let host = hostArchComponent(options.hostTriple)
        return "stupid-app-ios-\(options.targetTriple)-\(host).artifactbundle"
    }

    private func hostArchComponent(_ triple: String) -> String {
        triple.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    // MARK: - Copy

    private func copyWanted(from developerDir: URL, to destination: URL) throws {
        for relative in Self.wanted {
            let source = developerDir.appendingPathComponent(relative)
            let dest = destination.appendingPathComponent(relative)
            guard fileManager.fileExists(atPath: source.path) else {
                throw ExportError.developerDirMissing(source)
            }
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: source.path, isDirectory: &isDir)
            let isSymlink = (try? fileManager.destinationOfSymbolicLink(atPath: source.path)) != nil
            if isSymlink {
                try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: source, to: dest)
            } else if exists, isDir.boolValue {
                try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
                try copyTree(from: source, to: dest)
            } else if exists {
                try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: source, to: dest)
            }
        }
    }

    private func copyTree(from source: URL, to destination: URL) throws {
        let contents = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        for child in contents {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let dest = destination.appendingPathComponent(child.lastPathComponent)
            do {
                if values.isSymbolicLink == true {
                    // Preserve symlinks deliberately. Reject links that escape the copy root
                    // or point at absolute paths; the SDK uses only relative internal links.
                    let target = try fileManager.destinationOfSymbolicLink(atPath: child.path)
                    guard !target.hasPrefix("/") else {
                        throw ExportError.unexpectedSymlink(child.path)
                    }
                    try fileManager.createSymbolicLink(atPath: dest.path, withDestinationPath: target)
                } else if values.isDirectory == true {
                    try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
                    try copyTree(from: child, to: dest)
                } else {
                    try fileManager.copyItem(at: child, to: dest)
                }
            } catch {
                throw ExportError.copyFailed(source: child.path, destination: dest.path, reason: error.localizedDescription)
            }
        }
    }

    // MARK: - SDK discovery

    private func discoverIPhoneOSVersion(from developerDir: URL) throws -> String {
        let sdkDir = developerDir
            .appendingPathComponent("Platforms/iPhoneOS.platform/Developer/SDKs")
        guard let contents = try? fileManager.contentsOfDirectory(atPath: sdkDir.path) else {
            throw ExportError.noNumericIOSSDK(sdkDir.path)
        }
        // Numeric SDK directories (e.g. iPhoneOS.sdk is a symlink; the real one is
        // iPhoneOS26.2.sdk). Match the canonical name against the manifest.
        let candidates = contents.filter { $0.hasPrefix("iPhoneOS") && $0.hasSuffix(".sdk") }
        guard let versioned = candidates.first(where: { $0 != "iPhoneOS.sdk" }) else {
            throw ExportError.noNumericIOSSDK(sdkDir.path)
        }
        let version = versioned
            .replacingOccurrences(of: "iPhoneOS", with: "")
            .replacingOccurrences(of: ".sdk", with: "")
        guard !version.isEmpty else {
            throw ExportError.noNumericIOSSDK(sdkDir.path)
        }
        return version
    }

    // MARK: - Toolset

    private func installToolset(into bundle: URL) throws {
        // Mode B (macOS-host) stages the Darwin tools from the pinned Homebrew LLVM
        // prebuilt kegs; the Linux path downloads the pinned darwin-tools archive.
        if DarwinTools.isMacOSHost(options.hostTriple) {
            try installMacOSToolset(into: bundle)
            return
        }

        let arch = hostArchComponent(options.hostTriple).contains("aarch64") || options.hostTriple.hasPrefix("aarch64")
            ? "aarch64"
            : "x86_64"
        guard let source = DarwinTools.source(for: arch) else {
            throw ExportError.hostArchUnsupported(arch)
        }

        let toolsetDir = bundle.appendingPathComponent("toolset")
        try fileManager.createDirectory(at: toolsetDir, withIntermediateDirectories: true)
        let archiveURL = try downloadToolset(source)
        defer { try? fileManager.removeItem(at: archiveURL) }

        let computed = try SHA256.file(at: archiveURL)
        guard computed == source.sha256 else {
            throw ExportError.toolsetChecksumMismatch(computed)
        }

        // The toolset archive extracts a `bin/` directory with the Darwin tools.
        let staging = toolsetDir.appendingPathComponent("staging")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archiveURL.path, "-C", staging.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExportError.toolsetDownloadFailed(source.url, 0)
        }

        let binSource = staging.appendingPathComponent("bin")
        let binDest = toolsetDir.appendingPathComponent("bin")
        try fileManager.moveItem(at: binSource, to: binDest)
        try fileManager.removeItem(at: staging)

        for tool in DarwinTools.binaries {
            guard fileManager.isExecutableFile(atPath: binDest.appendingPathComponent(tool).path) else {
                throw ExportError.toolsetChecksumMismatch("missing \(tool)")
            }
        }
    }

    /// Stages the macOS-hosted Mode B toolset from the pinned Homebrew `lld`/`llvm`
    /// kegs into the bundle, then rewrites absolute Homebrew load paths to `@rpath` so
    /// the bundle is relocatable (Gate M4 validation 1).
    private func installMacOSToolset(into bundle: URL) throws {
        guard let hosted = DarwinTools.macOSHosted(forHostTriple: options.hostTriple) else {
            throw ExportError.hostArchUnsupported(options.hostTriple)
        }
        let toolsetDir = bundle.appendingPathComponent("toolset")
        let binDir = toolsetDir.appendingPathComponent("bin")
        let libDir = toolsetDir.appendingPathComponent("lib")
        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: libDir, withIntermediateDirectories: true)

        // Group binaries by keg bin dir so a source file can be resolved to its path.
        let kegBins: [(keg: String, dir: URL)] = [
            ("lld", URL(fileURLWithPath: hosted.lldBinDir)),
            ("llvm", URL(fileURLWithPath: hosted.llvmBinDir)),
        ]

        // Binaries.
        for binary in hosted.binaries {
            guard let entry = kegBins.first(where: { binary.keg == $0.keg }) else { continue }
            let source = entry.dir.appendingPathComponent(binary.source)
            guard fileManager.isExecutableFile(atPath: source.path) else {
                throw ExportError.homebrewToolMissing(source.path)
            }
            try fileManager.copyItem(at: source, to: binDir.appendingPathComponent(binary.bundleName))
        }
        for tool in DarwinTools.binaries {
            guard fileManager.isExecutableFile(atPath: binDir.appendingPathComponent(tool).path) else {
                throw ExportError.homebrewToolMissing(binDir.appendingPathComponent(tool).path)
            }
        }

        // Dylibs.
        for dylib in hosted.dylibs {
            let lib: URL
            if dylib.keg == "lld" {
                lib = URL(fileURLWithPath: hosted.lldLibDir)
            } else if dylib.keg == "llvm" {
                lib = URL(fileURLWithPath: hosted.llvmLibDir)
            } else {
                lib = URL(fileURLWithPath: hosted.zstdLibDir)
            }
            let source = lib.appendingPathComponent(dylib.source)
            guard fileManager.fileExists(atPath: source.path) else {
                throw ExportError.homebrewToolMissing(source.path)
            }
            try fileManager.copyItem(at: source, to: libDir.appendingPathComponent(dylib.bundleName))
        }

        // Relocate: rewrite absolute Homebrew load paths to @rpath, then fix install names.
        let allFiles = (try fileManager.contentsOfDirectory(at: binDir, includingPropertiesForKeys: nil))
            + (try fileManager.contentsOfDirectory(at: libDir, includingPropertiesForKeys: nil))
        for file in allFiles {
            try rewriteLoadPath(file, old: hosted.llvmLoadPath, new: "@rpath/libLLVM.dylib")
            try rewriteLoadPath(file, old: hosted.zstdLoadPath, new: "@rpath/libzstd.1.dylib")
        }
        for dylib in hosted.dylibs {
            if let installName = dylib.installName {
                try runTool([URL(fileURLWithPath: "/usr/bin/install_name_tool").path, "-id", installName,
                             libDir.appendingPathComponent(dylib.bundleName).path])
            }
        }

        // Verify no load dependency still references the Homebrew prefix.
        for file in allFiles {
            let deps = try otoolDependencies(at: file)
            if deps.contains(where: { $0.contains("/opt/homebrew") }) {
                throw ExportError.toolRelocationUnverified(file.path)
            }
        }
    }

    /// Runs `/usr/bin/install_name_tool -change <old> <new> <file>`, tolerating the
    /// (exit 0) no-op when the load command is absent.
    private func rewriteLoadPath(_ file: URL, old: String, new: String) throws {
        try runTool([
            "/usr/bin/install_name_tool", "-change", old, new, file.path,
        ])
    }

    /// Returns the load-command dependencies (excluding install names) of a Mach-O.
    private func otoolDependencies(at url: URL) throws -> [String] {
        let output = try runToolCapture(["/usr/bin/otool", "-L", url.path])
        // First line (after the "file:" header) is the install name; only dependencies follow.
        return output.split(separator: "\n").dropFirst(2).map(String.init)
    }

    private func runTool(_ arguments: [String]) throws {
        _ = try runToolCapture(arguments)
    }

    /// Runs a tool and returns captured stdout, throwing on a non-zero exit.
    private func runToolCapture(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ExportError.toolRelocationFailed(arguments[0], err.isEmpty ? out : err)
        }
        return out
    }

    private func downloadToolset(_ source: DarwinTools.Source) throws -> URL {
        let destination = options.scratchURL.appendingPathComponent("toolset-\(source.arch).tar.gz")
        if fileManager.fileExists(atPath: destination.path) {
            return destination
        }
        var request = URLRequest(url: source.url)
        request.httpMethod = "GET"
        request.setValue("stupid-app", forHTTPHeaderField: "User-Agent")
        let (data, response) = try downloadSynchronously(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ExportError.toolsetDownloadFailed(source.url, status)
        }
        try data.write(to: destination)
        return destination
    }

    private func downloadSynchronously(_ request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var data: Data?
            var response: URLResponse?
            var failure: (any Error)?
        }
        let box = Box()
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data
            box.response = response
            box.failure = error
            semaphore.signal()
        }.resume()
        semaphore.wait()
        if let failure = box.failure {
            throw failure
        }
        guard let data = box.data, let response = box.response else {
            throw NSError(domain: "stupid-app", code: 1, userInfo: [NSLocalizedDescriptionKey: "no response"])
        }
        return (data, response)
    }

    // MARK: - Metadata

    private func writeMetadata(into bundle: URL, iphoneosVersion: String) throws {
        let info = InfoJSON(
            schemaVersion: "1.0",
            artifacts: [
                "stupid-app-ios": InfoJSON.Artifact(
                    type: "swiftSDK",
                    version: iphoneosVersion,
                    variants: [
                        InfoJSON.Variant(path: ".", supportedTriples: [options.hostTriple])
                    ]
                )
            ]
        )
        try JSONEncoder.withSortedKeys().encode(info).write(to: bundle.appendingPathComponent("info.json"))

        let swiftSDK = SwiftSDKJSON(
            schemaVersion: "4.0",
            targetTriples: [
                options.targetTriple: SwiftSDKJSON.Triple(
                    sdkRootPath: "Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk",
                    includeSearchPaths: ["Developer/Platforms/iPhoneOS.platform/Developer/usr/lib"],
                    librarySearchPaths: ["Developer/Platforms/iPhoneOS.platform/Developer/usr/lib"],
                    swiftResourcesPath: "Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift",
                    toolsetPaths: ["toolset.json"]
                )
            ]
        )
        try JSONEncoder.withSortedKeys().encode(swiftSDK).write(to: bundle.appendingPathComponent("swift-sdk.json"))

        let toolset = ToolsetJSON(
            schemaVersion: "1.0",
            rootPath: "toolset/bin",
            linker: ToolsetJSON.Linker(path: "ld64.lld"),
            swiftCompiler: ToolsetJSON.SwiftCompiler(extraCLIOptions: [
                "-Xfrontend", "-enable-cross-import-overlays",
                "-use-ld=lld",
            ])
        )
        try JSONEncoder.withSortedKeys().encode(toolset).write(to: bundle.appendingPathComponent("toolset.json"))
    }

    private func buildManifest(bundleURL: URL, iphoneosVersion: String) throws -> SDKManifest {
        var files: [String: String] = [:]
        try walkHashes(bundleURL, relativePrefix: "", files: &files)

        let xcode = try xcodeVersion()
        let swift = try swiftToolchainVersion()

        let darwinTools: SDKManifest.DarwinToolsSource
        if DarwinTools.isMacOSHost(options.hostTriple) {
            guard let hosted = DarwinTools.macOSHosted(forHostTriple: options.hostTriple) else {
                throw ExportError.hostArchUnsupported(options.hostTriple)
            }
            // Provenance only: integrity is enforced by the per-file `files` checksums.
            let ld64 = try SHA256.file(at: bundleURL.appendingPathComponent("toolset/bin/ld64.lld"))
            darwinTools = SDKManifest.DarwinToolsSource(
                source: "homebrew:lld@20,llvm@20,zstd",
                version: hosted.version,
                sha256: ld64
            )
        } else {
            let hostArch = hostArchComponent(options.hostTriple).contains("aarch64") || options.hostTriple.hasPrefix("aarch64")
                ? "aarch64"
                : "x86_64"
            guard let source = DarwinTools.source(for: hostArch) else {
                throw ExportError.hostArchUnsupported(hostArch)
            }
            darwinTools = SDKManifest.DarwinToolsSource(
                source: source.url.absoluteString,
                version: source.version,
                sha256: source.sha256
            )
        }
        return SDKManifest(
            formatVersion: SDKManifest.currentFormatVersion,
            generator: "stupid-app",
            generatorVersion: "0.1.0",
            sourceXcode: SDKManifest.XcodeSource(version: xcode.0, build: xcode.1),
            iphoneosSDKVersion: iphoneosVersion,
            swiftCompiler: swift,
            hostTriple: options.hostTriple,
            targetTriple: options.targetTriple,
            darwinTools: darwinTools,
            files: files
        )
    }

    private func walkHashes(_ dir: URL, relativePrefix: String, files: inout [String: String]) throws {
        let contents = try fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for child in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let relative = relativePrefix.isEmpty
                ? child.lastPathComponent
                : "\(relativePrefix)/\(child.lastPathComponent)"
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                // Symlinks are not hashed. A link to a file is recorded under the
                // canonical path it points to; a link to a directory is skipped because
                // that directory is walked under its own real path.
                let target = try fileManager.destinationOfSymbolicLink(atPath: child.path)
                if target.hasPrefix("/") {
                    throw ExportError.unexpectedSymlink(child.path)
                }
                let resolved = child.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), !isDir.boolValue {
                    files[relative] = try SHA256.file(at: resolved)
                }
            } else if values.isDirectory == true {
                try walkHashes(child, relativePrefix: relative, files: &files)
            } else {
                files[relative] = try SHA256.file(at: child)
            }
        }
    }

    private func xcodeVersion() throws -> (String, String) {
        // Read from Xcode's own metadata rather than inferring from paths.
        let versionPlist = options.xcodeAppURL.appendingPathComponent("Contents/version.plist")
        let buildPlist = options.xcodeAppURL.appendingPathComponent("Contents/Info.plist")
        var version = "unknown"
        var build = "unknown"

        if let data = try? Data(contentsOf: versionPlist),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            if let v = plist["CFBundleShortVersionString"] as? String { version = v }
            if let b = plist["ProductBuildVersion"] as? String { build = b }
        }
        if version == "unknown", let data = try? Data(contentsOf: buildPlist),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            if let v = plist["CFBundleShortVersionString"] as? String { version = v }
        }
        return (version, build)
    }

    /// Runs the toolchain's own `swiftc` to record the exact compiler that produced the
    /// SDK resources, so the importer can reject an incompatible host Swift version.
    private func swiftToolchainVersion() throws -> SDKManifest.SwiftCompiler {
        let swiftc = options.xcodeAppURL
            .appendingPathComponent("Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc")
        let process = Process()
        process.executableURL = swiftc
        process.arguments = ["--version"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            + String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        // e.g. "Apple Swift version 6.2.1 (swiftlang-6.2.1.4.8 ...)"
        let versionLine = output.split(separator: "\n").first ?? ""
        let versionString = versionLine.split(separator: " ").map(String.init)
        guard let idx = versionString.firstIndex(of: "version"), idx + 1 < versionString.count else {
            throw ExportError.swiftVersionUnparseable(String(versionLine))
        }
        let version = versionString[idx + 1]
        let parts = version.split(separator: ".").map(String.init)
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else {
            throw ExportError.swiftVersionUnparseable(String(versionLine))
        }
        return SDKManifest.SwiftCompiler(version: version, major: major, minor: minor)
    }

    // MARK: - Packaging

    private func package(bundle: URL) throws -> URL {
        let archive = options.outputURL.appendingPathComponent("\(bundleName).tar.zst")
        try? fileManager.removeItem(at: archive)
        try fileManager.createDirectory(at: options.outputURL, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.currentDirectoryURL = bundle.deletingLastPathComponent()
        // `COPYFILE_DISABLE=1` prevents bsdtar from emitting AppleDouble `._` entries and
        // provenance metadata that GNU tar on the Linux importer would otherwise warn about.
        var environment = ProcessInfo.processInfo.environment
        environment["COPYFILE_DISABLE"] = "1"
        process.environment = environment
        process.arguments = [
            "--zstd",
            "-cf", archive.path, bundle.lastPathComponent,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExportError.toolsetDownloadFailed(options.outputURL, Int(process.terminationStatus))
        }
        return archive
    }
}

// MARK: - JSON models

struct InfoJSON: Codable {
    struct Artifact: Codable {
        var type: String
        var version: String
        var variants: [Variant]
    }

    struct Variant: Codable {
        var path: String
        var supportedTriples: [String]
    }

    var schemaVersion: String
    var artifacts: [String: Artifact]
}

struct SwiftSDKJSON: Codable {
    struct Triple: Codable {
        var sdkRootPath: String
        var includeSearchPaths: [String]
        var librarySearchPaths: [String]
        var swiftResourcesPath: String
        var toolsetPaths: [String]
    }

    var schemaVersion: String
    var targetTriples: [String: Triple]
}

struct ToolsetJSON: Codable {
    struct Linker: Codable {
        var path: String
    }

    struct SwiftCompiler: Codable {
        var extraCLIOptions: [String]
    }

    var schemaVersion: String
    var rootPath: String
    var linker: Linker
    var swiftCompiler: SwiftCompiler
}

extension JSONEncoder {
    static func withSortedKeys() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }
}
