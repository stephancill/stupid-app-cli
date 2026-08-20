import Foundation
import Testing

@testable import DeviceKit

struct CrashReportParsingTests {
  @Test("parses metadata and in-object exception and termination")
  func userModeJetsam() throws {
    let buffer = """
      {"bug_type":"298","name":"TorrentApp","app_name":"com.example.torrent","incident_id":"ABC123","os_version":"iPhone OS 26.3 (21E230)","timestamp":"2026-08-20 13:57:00.00 +0000"}
      {"exception":{"type":"EXC_BAD_ACCESS","subtype":"KERN_INVALID_ADDRESS"},"termination":{"namespace":"JETSAM","indicator":"61f","code":"0"},"faultingThread":0,"asi":{"message":"Killed while unresponsive"}}
      """
    let report = try CrashReportParsing.parse(buffer)

    #expect(report.name == "TorrentApp")
    #expect(report.bugType == "298")
    #expect(report.osVersion?.contains("26.3") == true)
    #expect(report.exceptionType == "EXC_BAD_ACCESS")
    #expect(report.exceptionSubtype == "KERN_INVALID_ADDRESS")
    #expect(report.terminationNamespace == "JETSAM")
    #expect(report.terminationCode == "0")
    #expect(report.terminationReason == "61f")
    #expect(report.applicationSpecificInformation == "Killed while unresponsive")
    #expect(report.impliesWatchdogOrResourceTermination == true)
  }

@Test("parses a watchdog termination reason")
  func watchdog() throws {
    let buffer = """
      {"bug_type":"298","name":"TorrentApp"}
      {"termination":{"namespace":"JETSAM","code":"0","reason":"CPU"}}
      """
    let report = try CrashReportParsing.parse(buffer)
    #expect(report.terminationNamespace == "JETSAM")
    #expect(report.terminationCode == "0")
    #expect(report.terminationReason == "CPU")
    #expect(report.impliesWatchdogOrResourceTermination == true)
  }

  @Test("a plain crash report is not classified as a watchdog termination")
  func nonWatchdog() throws {
    let buffer = """
      {"bug_type":"309","name":"App"}
      {"exception":{"type":"EXC_BREAKPOINT"},"termination":{"namespace":"SIGTRAP","code":"5"}}
      """
    let report = try CrashReportParsing.parse(buffer)
    #expect(report.exceptionType == "EXC_BREAKPOINT")
    #expect(report.terminationNamespace == "SIGTRAP")
    #expect(report.impliesWatchdogOrResourceTermination == false)
  }

  @Test("exposes only metadata for a legacy text payload")
  func legacyTextPayload() throws {
    let buffer = """
      {"bug_type":"panic","name":"panicname"}
      no json here
      line two
      """
    let report = try CrashReportParsing.parse(buffer)
    #expect(report.name == "panicname")
    #expect(report.bugType == "panic")
    #expect(report.exceptionType == nil)
    #expect(report.impliesWatchdogOrResourceTermination == false)
  }

  @Test("parses the Event/Action fields of a cpu_resource text report")
  func cpuResourceLegacy() throws {
    let buffer = """
      {"bug_type":"202","name":"TorrentApp","os_version":"iPhone OS 26.6 (23G71)"}
      Date/Time:        2026-08-20 14:37:51.606 +0200
      Command:          CrashApp
      Event:            cpu usage
      Action taken:     none
      CPU:              90 seconds cpu time over 118 seconds (76% cpu average), exceeding limit
      """
    let report = try CrashReportParsing.parse(buffer)
    #expect(report.bugType == "202")
    #expect(report.terminationReason == "cpu usage")
    #expect(report.terminationNamespace == "CPU_RESOURCE")
    #expect(report.impliesWatchdogOrResourceTermination == true)
  }

  @Test("rejects empty and newline-free buffers")
  func malformed() {
    #expect(throws: CrashReportParsing.Error.empty) {
      try CrashReportParsing.parse("  \n ")
    }
    #expect(throws: CrashReportParsing.Error.missingMetadataLine) {
      try CrashReportParsing.parse("no newline and not json")
    }
  }
}