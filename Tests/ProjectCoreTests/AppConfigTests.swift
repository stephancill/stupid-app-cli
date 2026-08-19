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

    @Test("extensions decode with product, bundleID, infoPath, and entitlements")
    func extensionsDecode() throws {
        let config = try decode("""
        version: 1
        product: StupidWidgets
        bundleID: net.stupidtech.widgets
        deploymentTarget: "17.0"
        infoPath: Info.plist
        entitlementsPath: App.entitlements
        extensions:
          - product: WidgetExtension
            bundleID: net.stupidtech.widgets.widget
            infoPath: WidgetExtension-Info.plist
            entitlementsPath: WidgetExtension.entitlements
            appIntentsMetadata: WidgetMetadata/Metadata.appintents
            resources:
              - WidgetMetadata/Metadata.appintents
        """)
        let extensions = try #require(config.extensions)
        #expect(extensions.count == 1)
        #expect(extensions[0].product == "WidgetExtension")
        #expect(extensions[0].bundleID == "net.stupidtech.widgets.widget")
        #expect(extensions[0].appIntentsMetadata == "WidgetMetadata/Metadata.appintents")
    }

    @Test("duplicate extension bundle IDs are rejected")
    func duplicateExtensionBundleIDs() {
        let yaml = """
        version: 1
        product: App
        bundleID: net.example.app
        deploymentTarget: "17.0"
        infoPath: Info.plist
        extensions:
          - product: ExtA
            bundleID: net.example.app.widget
            infoPath: A.plist
          - product: ExtB
            bundleID: net.example.app.widget
            infoPath: B.plist
        """
        #expect(throws: ProjectError.duplicateExtensionBundleID("net.example.app.widget")) {
            try decode(yaml)
        }
    }

    @Test("invalid extension product name is rejected")
    func invalidExtensionProduct() {
        let yaml = """
        version: 1
        product: App
        bundleID: net.example.app
        deploymentTarget: "17.0"
        infoPath: Info.plist
        extensions:
          - product: 1Bad Name!
            bundleID: net.example.app.widget
            infoPath: A.plist
        """
        #expect(throws: ProjectError.invalidExtensionProduct(
            "extensions[0]", "1Bad Name!")) {
            try decode(yaml)
        }
    }
}