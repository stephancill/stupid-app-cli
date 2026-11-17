import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

@testable import StupidAppMacros

/// The expansions follow Xcode 27's own plugins (dumped with `-dump-macro-expansions`).
/// Type-checking them against the real SDK is the other half of the check: compile an
/// app with `-load-plugin-executable <stupid-app-macros>#SwiftUIMacros,...` on a Mac.
final class ExpansionTests: XCTestCase {
  func testState() {
    assertMacroExpansion(
      """
      struct V {
        @State var count = 0
        @State private var name: String?
      }
      """,
      expandedSource: """
        struct V {
          var count {
              @storageRestrictions(initializes: _count)
              init(initialValue) {
                  _count = SwiftUICore.State(initialValue: initialValue)
              }
              get {
                  _count.wrappedValue
              }
              nonmutating set {
                  _count.wrappedValue = newValue
              }
          }

          private var _count = SwiftUICore.State(initialValue: 0)

          @SwiftUICore._PropertyWrapperProjectedValue
          var $count = SwiftUICore.State(initialValue: 0).projectedValue
          private var name: String? {
              @storageRestrictions(initializes: _name)
              init(initialValue) {
                  _name = SwiftUICore.State(initialValue: initialValue)
              }
              get {
                  _name.wrappedValue
              }
              nonmutating set {
                  _name.wrappedValue = newValue
              }
          }

          private var _name = SwiftUICore.State<String?>(initialValue: nil)

          @SwiftUICore._PropertyWrapperProjectedValue
          private var $name = SwiftUICore.State<String?>(initialValue: nil).projectedValue
        }
        """,
      macros: ["State": StateMacro.self]
    )
  }

  func testEntry() {
    assertMacroExpansion(
      """
      extension EnvironmentValues {
        @Entry var accent: Color = .red
      }
      """,
      expandedSource: """
        extension EnvironmentValues {
          var accent: Color {
              get {
                  self[__Key_accent.self]
              }
              set {
                  self[__Key_accent.self] = newValue
              }
              _modify {
                  yield &self[__Key_accent.self]
              }
          }

          private struct __Key_accent: SwiftUICore.EnvironmentKey {
              static var defaultValue: Color {
                  .red
              }
          }
        }
        """,
      macros: ["Entry": EntryMacro.self]
    )
  }

  func testEntryOutsideKnownContainersFails() {
    assertMacroExpansion(
      """
      extension FocusedValues {
        @Entry var thing: Int?
      }
      """,
      expandedSource: """
        extension FocusedValues {
          var thing: Int?
        }
        """,
      diagnostics: [
        DiagnosticSpec(
          message:
            "stupid-app-macros implements @Entry in EnvironmentValues, Transaction and ContainerValues, not 'FocusedValues'.",
          line: 2, column: 3),
        DiagnosticSpec(
          message:
            "stupid-app-macros implements @Entry in EnvironmentValues, Transaction and ContainerValues, not 'FocusedValues'.",
          line: 2, column: 3),
      ],
      macros: ["Entry": EntryMacro.self]
    )
  }

  func testPreviewExpandsToNothing() {
    assertMacroExpansion(
      """
      #Preview { V() }
      """,
      expandedSource: "",
      macros: ["Preview": NoDeclarationMacro.self]
    )
  }

  func testPersistedProperty() {
    assertMacroExpansion(
      """
      final class Item {
        @_PersistedProperty var name: String?
      }
      """,
      expandedSource: """
        final class Item {
          var name: String? {
              @storageRestrictions(accesses: _$backingData, initializes: _name)
              init(initialValue) {
                  _$backingData.setValue(forKey: \\.name, to: initialValue)
                  _name = _SwiftDataNoType()
              }
              get {
                  _$observationRegistrar.access(self, keyPath: \\.name)
                  return self.getValue(forKey: \\.name)
              }
              set {
                  _$observationRegistrar.withMutation(of: self, keyPath: \\.name) {
                      self.setValue(forKey: \\.name, to: newValue)
                  }
              }
          }

          @Transient
          private var _name: _SwiftDataNoType?
        }
        """,
      macros: ["_PersistedProperty": PersistedPropertyMacro.self]
    )
  }
}
