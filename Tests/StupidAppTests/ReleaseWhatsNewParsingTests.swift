import Foundation
import Testing

@testable import stupid_app

struct ReleaseWhatsNewParsingTests {
  static let bulletedNote = "- First change\n- Second change"

  @Test("external-beta takes a What to Test note that starts with a dash")
  func externalBetaDashNote() throws {
    let command = try ReleaseExternalBetaCommand.parse(["--whats-new", Self.bulletedNote, "--group-name", "External"])
    #expect(command.whatsNew == Self.bulletedNote)
    #expect(command.betaGroupName == "External")
  }

  @Test("beta-notes takes a What to Test note that starts with a dash")
  func betaNotesDashNote() throws {
    let command = try ReleaseBetaNotesCommand.parse(["--whats-new", Self.bulletedNote])
    #expect(command.whatsNew == Self.bulletedNote)
  }
}
