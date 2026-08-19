import Foundation
import ProjectCore
import Testing

/// Golden-fixture tests for `ProjectGenerator`: scaffold a project in a temp directory
/// and assert the exact generated file tree and that the generated `stupid-app.yml`
/// round-trips through `AppConfig`.
struct ProjectGeneratorTests {
    private func tempBase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stupid-app-gen-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("derives a module name by replacing hyphens with underscores")
    func moduleNameDerivation() {
        #expect(ProjectGenerator.moduleName(for: "AcceptanceApp") == "AcceptanceApp")
        #expect(ProjectGenerator.moduleName(for: "Foo-Bar") == "Foo_Bar")
    }

    @Test("generates the expected project file tree and config")
    func generatesGoldenTree() throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let icon = base.appendingPathComponent("icon.png")
        try Data([0x00, 0x01, 0x02]).write(to: icon)

        let config = try ProjectGenerator.generate(
            baseURL: base,
            options: .init(
                name: "HelloWorld",
                bundleID: "net.example.helloworld",
                deploymentTarget: "17.0",
                iconSource: icon.path
            )
        )

        #expect(config.product == "HelloWorld")
        #expect(config.bundleID == "net.example.helloworld")
        #expect(config.deploymentTarget == "17.0")

        let project = base.appendingPathComponent("HelloWorld")
        for relative in [
            "Package.swift",
            "stupid-app.yml",
            "Info.plist",
            "App.entitlements",
            "Sources/HelloWorld/HelloWorld.swift",
            "Sources/HelloWorld/ContentView.swift",
            "Resources/AppIcon.png",
        ] {
            #expect(
                FileManager.default.fileExists(atPath: project.appendingPathComponent(relative).path),
                "missing \(relative)"
            )
        }
    }

    @Test("the generated stupid-app.yml round-trips through AppConfig")
    func generatedConfigRoundTrips() throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        _ = try ProjectGenerator.generate(
            baseURL: base,
            options: .init(
                name: "RoundTrip",
                bundleID: "net.example.roundtrip",
                deploymentTarget: "17.0"
            )
        )
        let ymlURL = base.appendingPathComponent("RoundTrip/stupid-app.yml")
        let decoded = try AppConfig.decode(Data(contentsOf: ymlURL))
        #expect(decoded.product == "RoundTrip")
        #expect(decoded.bundleID == "net.example.roundtrip")
        #expect(decoded.infoPath == "Info.plist")
        #expect(decoded.entitlementsPath == "App.entitlements")
        #expect(decoded.iconPath == nil)
    }

    @Test("rejects an invalid product name")
    func invalidProductName() throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(throws: ProjectError.self) {
            try ProjectGenerator.generate(
                baseURL: base,
                options: .init(name: "1Bad Name!", bundleID: "net.example.app", deploymentTarget: "17.0")
            )
        }
    }

    @Test("rejects a destination that already exists")
    func existingDirectory() throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("Existing"), withIntermediateDirectories: true)
        #expect(throws: ProjectError.self) {
            try ProjectGenerator.generate(
                baseURL: base,
                options: .init(name: "Existing", bundleID: "net.example.app", deploymentTarget: "17.0")
            )
        }
    }

    @Test("rejects a non-PNG icon source")
    func nonPngIcon() throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let icon = base.appendingPathComponent("icon.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: icon)
        #expect(throws: ProjectError.self) {
            try ProjectGenerator.generate(
                baseURL: base,
                options: .init(
                    name: "App",
                    bundleID: "net.example.app",
                    deploymentTarget: "17.0",
                    iconSource: icon.path
                )
            )
        }
    }
}
