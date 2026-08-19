import Testing

@testable import stupid_app

struct DevicesFormatTests {
  @Test("device row uses %@ padding and does not crash on Swift Strings")
  func formattedRowPadsCorrectly() {
    // Regression: `String(format: "%-Ns", swiftString)` treats %s as a C pointer and
    // segfaults; %@ with %-Ns left-aligns Swift Strings safely.
    let row = DevicesListCommand.formattedRow(
      name: "iPhone", udid: "A1B2C3D4", status: "ENABLED", nameWidth: 6, udidWidth: 8, statusWidth: 7)
    #expect(row.contains("iPhone"))
    #expect(row.contains("A1B2C3D4"))
    #expect(row.contains("ENABLED"))
    #expect(row.hasPrefix("iPhone "))
    #expect(row.count == 6 + 2 + 8 + 2 + 7)
  }

  @Test("device row aligns a short value with trailing padding")
  func formattedRowPadsShortValue() {
    let row = DevicesListCommand.formattedRow(
      name: "X", udid: "Y", status: "Z", nameWidth: 4, udidWidth: 4, statusWidth: 4)
    #expect(row.hasPrefix("X   "))
    #expect(row.count == 4 + 2 + 4 + 2 + 4)
  }
}
