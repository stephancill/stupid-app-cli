import SwiftSyntax
import SwiftSyntaxMacros

/// `@Model`, written out as Xcode 27's SwiftDataMacros does: backing data, schema metadata,
/// observation, `@_PersistedProperty` on each persisted property, and the conformances.
struct PersistentModelMacro: MemberMacro, MemberAttributeMacro, ExtensionMacro {
  static func persisted(_ members: MemberBlockItemListSyntax) -> [StoredProperty] {
    members.compactMap { StoredProperty($0.decl) }.filter {
      !$0.isStatic && !$0.hasAccessors && !$0.hasAttribute("Transient")
        && !$0.name.hasPrefix("_$")
    }
  }

  static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard let classDecl = declaration.as(ClassDeclSyntax.self) else {
      throw MacroError("@Model applies to a class.")
    }
    let typeName = classDecl.name.text
    let isPublic = classDecl.modifiers.contains {
      [.keyword(.public), .keyword(.open)].contains($0.name.tokenKind)
    }
    let publicPrefix = isPublic ? "public " : ""
    let properties = persisted(declaration.memberBlock.members)
    let metadata = properties.map { property -> String in
      let defaultValue = property.initializer?.description ?? "nil"
      let schema: String
      if let attribute = property.attribute("Attribute") {
        schema = "SwiftData.Schema.Attribute(\(arguments(attribute)))"
      } else if let relationship = property.attribute("Relationship") {
        schema = "SwiftData.Schema.Relationship(\(arguments(relationship)))"
      } else {
        schema = "nil"
      }
      return
        "SwiftData.Schema.PropertyMetadata(name: \"\(property.name)\", keypath: \\\(typeName).\(property.name), defaultValue: \(defaultValue), metadata: \(schema))"
    }.joined(separator: ",\n    ")
    let placeholders = properties.map { "_\($0.name) = _SwiftDataNoType()" }
      .joined(separator: "\n  ")
    return [
      """
      @Transient
      private var _$backingData: any SwiftData.BackingData<\(raw: typeName)> = \(raw: typeName).createBackingData()
      """,
      """
      public var persistentBackingData: any SwiftData.BackingData<\(raw: typeName)> {
          get { return _$backingData }
          set { _$backingData = newValue }
      }
      """,
      """
      \(raw: publicPrefix)class var schemaMetadata: [SwiftData.Schema.PropertyMetadata] {
        return [
          \(raw: metadata)
        ]
      }
      """,
      """
      \(raw: publicPrefix)init(backingData: any SwiftData.BackingData<\(raw: typeName)>) {
        \(raw: placeholders)
        self.persistentBackingData = backingData
      }
      """,
      "@Transient private let _$observationRegistrar = Observation.ObservationRegistrar()",
      """
      internal nonisolated func access<_M>(keyPath: KeyPath<\(raw: typeName), _M>) {
        _$observationRegistrar.access(self, keyPath: keyPath)
      }
      """,
      """
      internal nonisolated func withMutation<_M, _MR>(
        keyPath: KeyPath<\(raw: typeName), _M>,
        _ mutation: () throws -> _MR
      ) rethrows -> _MR {
        try _$observationRegistrar.withMutation(of: self, keyPath: keyPath, mutation)
      }
      """,
      "struct _SwiftDataNoType {}",
    ]
  }

  static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingAttributesFor member: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [AttributeSyntax] {
    guard let property = StoredProperty(member),
      !property.isStatic, !property.hasAccessors, !property.hasAttribute("Transient"),
      !property.hasAttribute("_PersistedProperty"), !property.name.hasPrefix("_$")
    else { return [] }
    return ["@_PersistedProperty"]
  }

  static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    let names = protocols.map { $0.trimmedDescription }
    var extensions: [DeclSyntax] = []
    if names.contains(where: { $0.hasSuffix("PersistentModel") }) {
      extensions.append("extension \(type.trimmed): nonisolated SwiftData.PersistentModel {}")
    }
    if names.contains(where: { $0.hasSuffix("Observable") }) {
      extensions.append("extension \(type.trimmed): nonisolated Observation.Observable {}")
    }
    if names.contains(where: { $0.hasSuffix("Sendable") }) {
      let message =
        "PersistentModels are not Sendable, consider utilizing a ModelActor or use \(type.trimmedDescription)'s persistentModelID instead"
      extensions.append(
        """
        @available(swift, deprecated: 5.9, message: "\(raw: message)")
        @available(*, unavailable, message: "\(raw: message)")
        extension \(type.trimmed): Sendable {}
        """)
    }
    return extensions.compactMap { $0.as(ExtensionDeclSyntax.self) }
  }

  private static func arguments(_ attribute: AttributeSyntax) -> String {
    guard case .argumentList(let arguments) = attribute.arguments else { return "" }
    return arguments.trimmedDescription
  }
}

/// `@_PersistedProperty`: reads and writes through the model's backing data, observed.
struct PersistedPropertyMacro: AccessorMacro, PeerMacro {
  static func expansion(
    of node: AttributeSyntax,
    providingAccessorsOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [AccessorDeclSyntax] {
    guard let property = StoredProperty(declaration) else {
      throw MacroError("@_PersistedProperty applies to a single stored `var`.")
    }
    let name = property.name
    return [
      """
      @storageRestrictions(accesses: _$backingData, initializes: _\(raw: name))
      init(initialValue) {
          _$backingData.setValue(forKey: \\.\(raw: name), to: initialValue)
          _\(raw: name) = _SwiftDataNoType()
      }
      """,
      """
      get {
          _$observationRegistrar.access(self, keyPath: \\.\(raw: name))
          return self.getValue(forKey: \\.\(raw: name))
      }
      """,
      """
      set {
          _$observationRegistrar.withMutation(of: self, keyPath: \\.\(raw: name)) {
              self.setValue(forKey: \\.\(raw: name), to: newValue)
          }
      }
      """,
    ]
  }

  static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard let property = StoredProperty(declaration) else {
      throw MacroError("@_PersistedProperty applies to a single stored `var`.")
    }
    let type = property.isOptional ? "_SwiftDataNoType?" : "_SwiftDataNoType"
    let initial = property.initializer == nil ? "" : " = _SwiftDataNoType()"
    return ["@Transient\nprivate var _\(raw: property.name): \(raw: type)\(raw: initial)"]
  }
}
