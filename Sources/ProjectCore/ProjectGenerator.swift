import Foundation

/// Scaffolds a new SwiftPM/SwiftUI application project in the `stupid-app`
/// supported project model. The generator writes only source files; it never
/// invokes Xcode or the build system.
public enum ProjectGenerator {
    public struct Options: Sendable {
        public var name: String
        public var bundleID: String
        public var deploymentTarget: String
        public var iconSource: String?

        public init(name: String, bundleID: String, deploymentTarget: String, iconSource: String? = nil) {
            self.name = name
            self.bundleID = bundleID
            self.deploymentTarget = deploymentTarget
            self.iconSource = iconSource
        }
    }

    /// The module name derived from the product name (`Foo-Bar` -> `Foo_Bar`).
    public static func moduleName(for name: String) -> String {
        name.replacingOccurrences(of: "-", with: "_")
    }

    /// Creates the project directory and all source files at `baseURL`/`name`.
    public static func generate(baseURL: URL, options: Options) throws -> AppConfig {
        guard AppConfig.isValidProductName(options.name) else {
            throw ProjectError.invalidProductName(options.name)
        }
        let projectURL = baseURL.appendingPathComponent(options.name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: projectURL.path) else {
            throw ProjectError.fileExists(projectURL.path)
        }
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let module = moduleName(for: options.name)
        let files: [(String, String)] = [
            ("Package.swift", packageSwift(name: options.name, module: module)),
            ("stupid-app.yml", configYAML(name: options.name, module: module, options: options)),
            ("Info.plist", infoPlist(name: options.name, bundleID: options.bundleID, target: options.deploymentTarget)),
            ("App.entitlements", entitlements()),
            ("Sources/\(module)/\(module).swift", appSwift(module: module)),
            ("Sources/\(module)/ContentView.swift", contentViewSwift()),
        ]

        for (relative, contents) in files {
            let url = projectURL.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        if let iconSource = options.iconSource {
            let sourceURL = URL(fileURLWithPath: iconSource)
            guard sourceURL.pathExtension.lowercased() == "png" else {
                throw ProjectError.iconNotPng(iconSource)
            }
            let iconDir = projectURL.appendingPathComponent("Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: iconDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: sourceURL,
                to: iconDir.appendingPathComponent("AppIcon.png")
            )
        }

        return try AppConfig(
            version: 1,
            product: options.name,
            bundleID: options.bundleID,
            deploymentTarget: options.deploymentTarget,
            infoPath: "Info.plist",
            entitlementsPath: "App.entitlements",
            iconPath: options.iconSource == nil ? nil : "Resources/AppIcon.png"
        )
    }

    private static func packageSwift(name: String, module: String) -> String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "\(name)",
            platforms: [
                .iOS(.v17)
            ],
            products: [
                // A stupid-app project contains exactly one library product
                // representing the application.
                .library(
                    name: "\(module)",
                    targets: ["\(module)"]
                )
            ],
            targets: [
                .target(
                    name: "\(module)"
                )
            ]
        )
        """
    }

    private static func configYAML(name: String, module _: String, options: Options) -> String {
        var lines = [
            "version: 1",
            "product: \(name)",
            "bundleID: \(options.bundleID)",
            "deploymentTarget: \"\(options.deploymentTarget)\"",
            "infoPath: Info.plist",
            "entitlementsPath: App.entitlements",
        ]
        if options.iconSource != nil {
            lines.append("iconPath: Resources/AppIcon.png")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func infoPlist(name: String, bundleID: String, target: String) -> String {
        // The packer overlays this source plist over the baseline keys (deployment
        // target, executable name, etc.). Keep only app-authored keys here.
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDisplayName</key>
            <string>\(name)</string>
            <key>CFBundleIdentifier</key>
            <string>\(bundleID)</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0.0</string>
            <key>CFBundleVersion</key>
            <string>1</string>
            <key>MinimumOSVersion</key>
            <string>\(target)</string>
            <key>UIApplicationSceneManifest</key>
            <dict>
                <key>UIApplicationSupportsMultipleScenes</key>
                <false/>
            </dict>
        </dict>
        </plist>
        """
    }

    private static func entitlements() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        </dict>
        </plist>
        """
    }

    private static func appSwift(module: String) -> String {
        """
        import SwiftUI

        @main
        struct \(module)App: App {
            var body: some Scene {
                WindowGroup {
                    ContentView()
                }
            }
        }
        """
    }

    private static func contentViewSwift() -> String {
        """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack {
                    Image(systemName: "globe")
                        .imageScale(.large)
                        .foregroundStyle(.tint)
                    Text("Hello, world!")
                }
                .padding()
            }
        }
        """
    }
}