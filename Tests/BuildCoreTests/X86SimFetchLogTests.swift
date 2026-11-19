import Foundation
import Testing

@testable import BuildCore

/// The fetch log stupid simulator's lazy runtime writes (`layers/lazy.log`), as `run --simulator`
/// reads it when an app does not come to the front.
struct X86SimFetchLogTests {
  @Test func picksOnlyTheFailedFetches() {
    let log = """
      09:00:01 serving ios-27.2-24B8117-arm64 at /root/.local/share/x86sim/runtimes/ios-27.2-24B8117-arm64/layers/lazy
      09:00:05 fetched System/Library/Frameworks/MapKit.framework: 12 files, 3.1 MB (1.2 MB compressed) in 0.31 s, for MapKit
      09:00:07 FAILED fetching System/Library/Frameworks/Foo.framework (unit 7, blob-000 10+20) for Foo: curl 22
      09:00:08 fetched Applications/Maps.app: 30 files, 9.0 MB (4.0 MB compressed) in 0.40 s, for Maps
      """
    let failed = X86Sim.failedFetches(inLog: log)
    #expect(failed.count == 1)
    #expect(failed.first?.contains("Foo.framework") == true)
  }

  @Test func keepsTheLastOnes() {
    let log = (1...8).map { "09:00:0\($0) FAILED fetching unit \($0)" }.joined(separator: "\n")
    let failed = X86Sim.failedFetches(inLog: log, limit: 3)
    #expect(
      failed == [
        "09:00:06 FAILED fetching unit 6", "09:00:07 FAILED fetching unit 7",
        "09:00:08 FAILED fetching unit 8",
      ])
  }

  @Test func nothingFailedIsEmpty() {
    #expect(X86Sim.failedFetches(inLog: "09:00:05 fetched Applications/Maps.app: 30 files").isEmpty)
  }
}
