@_spi(PluginMessage) import SwiftCompilerPluginMessageHandling
import SwiftSyntaxMacros
import VendoredFoundationMacros

/// One executable serving the three closed-source macro modules Xcode's iOS SDK refers to.
/// The compiler names the module and type it wants; types are looked up per module, so a
/// macro this plugin does not implement is reported by name instead of guessed.
/// (swift-syntax's `CompilerPlugin` matches only the executable's own module name, so the
/// message loop is run directly with a provider that maps the three module names.)
@main
struct StupidAppMacrosPlugin: PluginProvider {
  static let macros: [String: Macro.Type] = [
    "SwiftUIMacros.StateMacro": StateMacro.self,
    "SwiftUIMacros.ProjectedValueMacro": ProjectedValueMacro.self,
    "SwiftUIMacros.EntryMacro": EntryMacro.self,
    "SwiftUIMacros.EntryDefaultValueMacro": EntryDefaultValueMacro.self,
    "SwiftDataMacros.PersistentModelMacro": PersistentModelMacro.self,
    "SwiftDataMacros.PersistedPropertyMacro": PersistedPropertyMacro.self,
    "SwiftDataMacros.TransientPropertyMacro": NoPeerMacro.self,
    "SwiftDataMacros.AttributePropertyMacro": NoPeerMacro.self,
    "SwiftDataMacros.RelationshipPropertyMacro": NoPeerMacro.self,
    "PreviewsMacros.SwiftUIView": NoDeclarationMacro.self,
    "PreviewsMacros.Common": NoDeclarationMacro.self,
    "PreviewsMacros.KitViewMacro": NoDeclarationMacro.self,
    "PreviewsMacros.PreviewCommonGroup": NoDeclarationMacro.self,
    "PreviewsMacros.Previewable": NoPeerMacro.self,
    // swift-foundation's own macros, built to emit `Foundation` names (see
    // Sources/VendoredFoundationMacros/README.md).
    "FoundationMacros.PredicateMacro": VendoredFoundationMacros.PredicateMacro.self,
    "FoundationMacros.ExpressionMacro": VendoredFoundationMacros.ExpressionMacro.self,
    "FoundationMacros.BundleMacro": VendoredFoundationMacros.BundleMacro.self,
  ]

  func resolveMacro(moduleName: String, typeName: String) throws -> Macro.Type {
    guard let macro = Self.macros["\(moduleName).\(typeName)"] else {
      throw MacroError(
        "stupid-app-macros does not implement \(moduleName).\(typeName), which Xcode's plugin provides on macOS only."
      )
    }
    return macro
  }

  static func main() throws {
    let connection = try StandardIOMessageConnection()
    let listener = CompilerPluginMessageListener(
      connection: connection, provider: StupidAppMacrosPlugin())
    try listener.main()
  }
}
