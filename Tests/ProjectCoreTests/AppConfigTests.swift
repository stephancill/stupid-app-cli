import Foundation
import ProjectCore
import Testing

@testable import ProjectCore

struct AppConfigTests {
    private func decode(_ yaml: String) throws -> AppConfig {
        try AppConfig.decode(Data(yaml.utf8))
    }

    @Test("minimal valid config decodes and validates")
    func validConfig() throws {
        let config = try decode("""
        version: 1
        product: AcceptanceApp
        bundleID: net.example.acceptance-app
        deploymentTarget: "17.0"
        infoPath: Info.plist
        entitlementsPath: App.entitlements
        """)
        #expect(config.product == "AcceptanceApp")
        #expect(config.bundleID == "net.example.acceptance-app")
        #expect(config.deploymentTarget == "17.0")
    }

    @Test("unsupported schema version is rejected")
    func unsupportedVersion() {
        let yaml = """
        version: 99
        product: App
        bundleID: net.example.app
        deploymentTarget: "17.0"
        infoPath: Info.plist
        """
        #expect(throws: ProjectError.unsupportedVersion(99)) {
            try decode(yaml)
        }
    }

    @Test("missing required field is rejected")
    func missingProduct() {
        let yaml = """
        version: 1
        bundleID: net.example.app
        deploymentTarget: "17.0"
        infoPath: Info.plist
        """
        #expect(throws: ProjectError.self) {
            try decode(yaml)
        }
    }

    @Test("invalid product name is rejected")
    func invalidProduct() {
        let yaml = """
        version: 1
        product: 1Bad Name!
        bundleID: net.example.app
        deploymentTarget: "17.0"
        infoPath: Info.plist
        """
        #expect(throws: ProjectError.self) {
            try decode(yaml)
        }
    }

    @Test("XTL- prefixed bundle ID is rejected (project invariant)")
    func xtlPrefixRejected() {
        let yaml = """
        version: 1
        product: App
        bundleID: XTL-AAAA1111.example.app
        deploymentTarget: "17.0"
        infoPath: Info.plist
        """
        #expect(throws: ProjectError.self) {
            try decode(yaml)
        }
    }

    @Test("absolute infoPath is rejected")
    func absolutePathRejected() {
        let yaml = """
        version: 1
        product: App
        bundleID: net.example.app
        deploymentTarget: "17.0"
        infoPath: /etc/Info.plist
        """
        #expect(throws: ProjectError.self) {
            try decode(yaml)
        }
    }

    @Test("path escaping project root is rejected")
    func pathEscapeRejected() {
        let yaml = """
        version: 1
        product: App
        bundleID: net.example.app
        deploymentTarget: "17.0"
        infoPath: ../Info.plist
        """
        #expect(throws: ProjectError.self) {
            try decode(yaml)
        }
    }

    @Test("non-png icon is rejected")
    func nonPngIconRejected() {
        let yaml = """
        version: 1
        product: App
        bundleID: net.example.app
        deploymentTarget: "17.0"
        infoPath: Info.plist
        iconPath: Resources/AppIcon.jpg
        """
        #expect(throws: ProjectError.self) {
            try decode(yaml)
        }
    }

    @Test("bundle ID format validation")
    func bundleIDValidation() {
        #expect(AppConfig.isValidBundleID("net.example.acceptance-app"))
        #expect(!AppConfig.isValidBundleID("not-a-bundle"))
        #expect(!AppConfig.isValidBundleID("net.example."))
        #expect(!AppConfig.isValidBundleID(""))
        #expect(!AppConfig.isValidBundleID("net..example.app"))
    }

    @Test("deployment target validation")
    func deploymentTargetValidation() {
        #expect(AppConfig.isValidVersion("17.0"))
        #expect(AppConfig.isValidVersion("17"))
        #expect(!AppConfig.isValidVersion("17.0-beta"))
        #expect(!AppConfig.isValidVersion(""))
        #expect(!AppConfig.isValidVersion("abc"))
    }
}