import Foundation
import Testing
@testable import ASCKit

/// Unit tests for device, certificate, and profile operation decoding using synthetic
/// fixtures. No credentials or live API calls.
struct ASCOperationsTests {
    // MARK: - Devices

    @Test("decodes a device list and finds an exact UDID")
    func decodeDeviceList() throws {
        let json = """
        {
          "data": [
            {
              "type": "devices",
              "id": "device-1",
              "attributes": {
                "name": "Stephen's iPhone",
                "udid": "00008100-0000000000000000",
                "platform": "IOS",
                "status": "ENABLED"
              }
            },
            {
              "type": "devices",
              "id": "device-2",
              "attributes": {
                "name": "Other",
                "udid": "another-udid",
                "platform": "IOS",
                "status": "ENABLED"
              }
            }
          ]
        }
        """
        let devices = try ASCOperations.decodeDeviceList(Data(json.utf8))
        #expect(devices.count == 2)
        #expect(devices[0].id == "device-1")
        #expect(devices[0].udid == "00008100-0000000000000000")
        #expect(devices[0].status == "ENABLED")
    }

    @Test("decodes a created device response")
    func decodeCreatedDevice() throws {
        let json = """
        {
          "data": {
            "type": "devices",
            "id": "device-9",
            "attributes": { "udid": "00008100-0000000000000000" }
          }
        }
        """
        let device = try ASCOperations.decodeCreatedDevice(Data(json.utf8))
        #expect(device.id == "device-9")
        #expect(device.udid == "00008100-0000000000000000")
    }

    // MARK: - Profiles

    @Test("matches a profile by exact name")
    func matchProfileByName() throws {
        let json = """
        {
          "data": [
            {
              "type": "profiles",
              "id": "profile-1",
              "attributes": { "name": "net.example.app Development", "profileType": "IOS_APP_DEVELOPMENT", "profileState": "ACTIVE" }
            },
            {
              "type": "profiles",
              "id": "profile-2",
              "attributes": { "name": "net.example.app AppStore", "profileType": "IOS_APP_STORE", "profileState": "ACTIVE" }
            }
          ]
        }
        """
        let development = try ASCOperations.matchProfileID(
            in: Data(json.utf8), name: "net.example.app Development", profileType: .development
        )
        #expect(development == "profile-1")
        let appStore = try ASCOperations.matchProfileID(
            in: Data(json.utf8), name: "net.example.app AppStore", profileType: .appStore
        )
        #expect(appStore == "profile-2")
    }

    @Test("does not match a profile of the wrong type")
    func matchProfileTypeIsRespected() throws {
        let json = """
        {
          "data": [
            {
              "type": "profiles",
              "id": "profile-1",
              "attributes": { "name": "net.example.app", "profileType": "IOS_APP_STORE", "profileState": "ACTIVE" }
            }
          ]
        }
        """
        let development = try ASCOperations.matchProfileID(
            in: Data(json.utf8), name: "net.example.app", profileType: .development
        )
        #expect(development == nil)
    }

    @Test("decodes a created profile resource ID")
    func decodeCreatedProfile() throws {
        let json = """
        {
          "data": { "type": "profiles", "id": "profile-42" }
        }
        """
        let id = try ASCOperations.decodeCreatedResourceID(Data(json.utf8), resource: "profiles create")
        #expect(id == "profile-42")
    }

    @Test("decodes a profile list with a bundled bundle identifier")
    func decodeProfileList() throws {
        let json = """
        {
          "data": [
            {
              "type": "profiles",
              "id": "profile-1",
              "attributes": {
                "name": "net.example.app Development",
                "profileType": "IOS_APP_DEVELOPMENT",
                "profileState": "ACTIVE",
                "expirationDate": "2027-08-01T12:00:00.000Z"
              },
              "relationships": {
                "bundleId": { "data": { "type": "bundleIds", "id": "bundle-9" } }
              }
            }
          ],
          "included": [
            {
              "type": "bundleIds",
              "id": "bundle-9",
              "attributes": { "identifier": "net.example.app" }
            }
          ]
        }
        """
        let summaries = try ASCOperations.decodeProfileList(Data(json.utf8))
        #expect(summaries.count == 1)
        #expect(summaries[0].id == "profile-1")
        #expect(summaries[0].bundleIdentifier == "net.example.app")
        #expect(summaries[0].state == "ACTIVE")
    }
}
