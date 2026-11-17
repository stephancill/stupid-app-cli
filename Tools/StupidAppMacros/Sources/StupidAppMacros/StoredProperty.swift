import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// A single-binding `var` declaration as the macros see it.
struct StoredProperty {
  var name: String
  var type: TypeSyntax?
  var initializer: ExprSyntax?
  /// The declaration's access modifier (`private `, `public `, ... or empty), with a
  /// trailing space so it can prefix generated declarations.
  var access: String
  var isStatic: Bool
  var hasAccessors: Bool
  var attributes: AttributeListSyntax

  init?(_ declaration: some DeclSyntaxProtocol) {
    guard let variable = declaration.as(VariableDeclSyntax.self),
      variable.bindingSpecifier.tokenKind == .keyword(.var),
      variable.bindings.count == 1,
      let binding = variable.bindings.first,
      let identifier = binding.pattern.as(IdentifierPatternSyntax.self)
    else { return nil }
    name = identifier.identifier.text
    type = binding.typeAnnotation?.type.trimmed
    initializer = binding.initializer?.value.trimmed
    hasAccessors = binding.accessorBlock != nil
    attributes = variable.attributes
    var access = ""
    var isStatic = false
    for modifier in variable.modifiers {
      switch modifier.name.tokenKind {
      case .keyword(.private), .keyword(.fileprivate), .keyword(.internal), .keyword(.public),
        .keyword(.package), .keyword(.open):
        // `private(set)` restricts the setter only; the declaration keeps its access.
        if modifier.detail == nil { access = "\(modifier.name.text) " }
      case .keyword(.static), .keyword(.class):
        isStatic = true
      default:
        break
      }
    }
    self.access = access
    self.isStatic = isStatic
  }

  var isOptional: Bool {
    guard let type else { return false }
    if type.is(OptionalTypeSyntax.self) || type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
      return true
    }
    return type.trimmedDescription.hasPrefix("Optional<")
      || type.trimmedDescription.hasPrefix("Swift.Optional<")
  }

  func hasAttribute(_ name: String) -> Bool {
    attribute(name) != nil
  }

  func attribute(_ name: String) -> AttributeSyntax? {
    for element in attributes {
      guard let attribute = element.as(AttributeSyntax.self) else { continue }
      let written = attribute.attributeName.trimmedDescription
      if written == name || written.hasSuffix(".\(name)") { return attribute }
    }
    return nil
  }
}

struct MacroError: Error, CustomStringConvertible {
  var description: String
  init(_ description: String) { self.description = description }
}
