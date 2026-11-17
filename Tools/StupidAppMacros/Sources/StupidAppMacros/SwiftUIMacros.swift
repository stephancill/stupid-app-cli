import SwiftSyntax
import SwiftSyntaxMacros

/// `@State`: the storage Xcode 27's SwiftUIMacros generates for the common case, which is
/// the classic `State` property wrapper written out (`_x`, `$x` and accessors). Apple's
/// plugin uses a lazily initialized storage for `private` typed properties instead; that
/// is an optimisation, and this form behaves like apps built with earlier SDKs.
struct StateMacro: AccessorMacro, PeerMacro {
  static func expansion(
    of node: AttributeSyntax,
    providingAccessorsOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [AccessorDeclSyntax] {
    guard let property = StoredProperty(declaration), !property.isStatic else {
      throw MacroError("@State applies to a single stored instance `var`.")
    }
    let storage = "_\(property.name)"
    return [
      """
      @storageRestrictions(initializes: \(raw: storage))
      init(initialValue) {
          \(raw: storage) = SwiftUICore.State(initialValue: initialValue)
      }
      """,
      "get { \(raw: storage).wrappedValue }",
      "nonmutating set { \(raw: storage).wrappedValue = newValue }",
    ]
  }

  static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard let property = StoredProperty(declaration), !property.isStatic else {
      throw MacroError("@State applies to a single stored instance `var`.")
    }
    let initial = initialValue(of: node) ?? property.initializer
    let state: String?
    if let initial {
      state =
        property.type.map { "SwiftUICore.State<\($0)>(initialValue: \(initial))" }
        ?? "SwiftUICore.State(initialValue: \(initial))"
    } else if property.isOptional, let type = property.type {
      state = "SwiftUICore.State<\(type)>(initialValue: nil)"
    } else {
      state = nil
    }
    guard state != nil || property.type != nil else {
      throw MacroError("@State needs an initial value or a type annotation.")
    }
    let storage: DeclSyntax =
      state.map { "private var _\(raw: property.name) = \(raw: $0)" }
      ?? "private var _\(raw: property.name): SwiftUICore.State<\(raw: property.type!)>"
    let projected: DeclSyntax =
      state.map {
        """
        @SwiftUICore._PropertyWrapperProjectedValue
        \(raw: property.access)var $\(raw: property.name) = \(raw: $0).projectedValue
        """
      }
      ?? """
      @SwiftUICore._PropertyWrapperProjectedValue
      \(raw: property.access)var $\(raw: property.name): SwiftUICore.Binding<\(raw: property.type!)>
      """
    return [storage, projected]
  }

  /// `@State(initialValue:)` and `@State(wrappedValue:)` carry the initial value.
  private static func initialValue(of node: AttributeSyntax) -> ExprSyntax? {
    guard case .argumentList(let arguments) = node.arguments else { return nil }
    return arguments.first(where: {
      ["initialValue", "wrappedValue"].contains($0.label?.text)
    })?.expression.trimmed
  }
}

/// `@_PropertyWrapperProjectedValue` on `$x`: reads `_x.projectedValue`.
struct ProjectedValueMacro: AccessorMacro {
  static func expansion(
    of node: AttributeSyntax,
    providingAccessorsOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [AccessorDeclSyntax] {
    guard let property = StoredProperty(declaration), property.name.hasPrefix("$") else {
      throw MacroError("@_PropertyWrapperProjectedValue applies to a `$` property.")
    }
    return ["get { _\(raw: property.name.dropFirst()).projectedValue }"]
  }
}

/// `@Entry` in an extension of EnvironmentValues, Transaction or ContainerValues: a private
/// key type holding the default, and accessors through the key, as Apple's macro writes them.
struct EntryMacro: AccessorMacro, PeerMacro {
  static func expansion(
    of node: AttributeSyntax,
    providingAccessorsOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [AccessorDeclSyntax] {
    guard let property = StoredProperty(declaration) else {
      throw MacroError("@Entry applies to a single `var`.")
    }
    _ = try keyProtocol(context)
    let key = "__Key_\(property.name)"
    return [
      "get { self[\(raw: key).self] }",
      "set { self[\(raw: key).self] = newValue }",
      "_modify { yield &self[\(raw: key).self] }",
    ]
  }

  static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard let property = StoredProperty(declaration) else {
      throw MacroError("@Entry applies to a single `var`.")
    }
    let keyProtocol = try keyProtocol(context)
    let defaultValue: String
    if let initializer = property.initializer {
      defaultValue = initializer.description
    } else if property.isOptional {
      defaultValue = "nil"
    } else {
      throw MacroError("@Entry needs a default value.")
    }
    guard let type = property.type else {
      throw MacroError("@Entry needs a type annotation, e.g. `@Entry var tint: Color = .red`.")
    }
    return [
      """
      private struct __Key_\(raw: property.name): \(raw: keyProtocol) {
          static var defaultValue: \(raw: type) { \(raw: defaultValue) }
      }
      """
    ]
  }

  private static func keyProtocol(_ context: some MacroExpansionContext) throws -> String {
    let container = context.lexicalContext.lazy.compactMap { scope -> String? in
      if let extensionDecl = scope.as(ExtensionDeclSyntax.self) {
        return extensionDecl.extendedType.trimmedDescription
      }
      return nil
    }.first ?? ""
    switch container.split(separator: ".").last.map(String.init) ?? "" {
    case "EnvironmentValues": return "SwiftUICore.EnvironmentKey"
    case "Transaction": return "SwiftUICore.TransactionKey"
    case "ContainerValues": return "SwiftUI.ContainerValueKey"
    default:
      throw MacroError(
        "stupid-app-macros implements @Entry in EnvironmentValues, Transaction and ContainerValues, not '\(container)'."
      )
    }
  }
}

/// `@__EntryDefaultValue`: the key's default, computed on each read.
struct EntryDefaultValueMacro: AccessorMacro {
  static func expansion(
    of node: AttributeSyntax,
    providingAccessorsOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [AccessorDeclSyntax] {
    guard let initializer = StoredProperty(declaration)?.initializer else {
      throw MacroError("@__EntryDefaultValue needs a default value.")
    }
    return ["get { \(initializer) }"]
  }
}

/// Previews exist for Xcode's canvas only; a simulator or device build has no use for them.
struct NoDeclarationMacro: DeclarationMacro {
  static func expansion(
    of node: some FreestandingMacroExpansionSyntax,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] { [] }
}

/// Markers whose meaning another macro reads (`@Transient`, `@Attribute`, `@Relationship`,
/// `@Previewable`): they generate nothing themselves.
struct NoPeerMacro: PeerMacro {
  static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] { [] }
}
