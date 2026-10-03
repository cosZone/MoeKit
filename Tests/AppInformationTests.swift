import Foundation
import Testing
@testable import MoeKit

@Suite("About information and public links")
struct AppInformationTests {
    @Test("About uses the actual version, build and copyright from the bundle")
    func bundleMetadata() {
        let information = AppInformation(infoDictionary: [
            "CFBundleShortVersionString": "0.3.1",
            "CFBundleVersion": "42",
            "NSHumanReadableCopyright": "Copyright © 2026 MoeKit"
        ])
        #expect(information.version == "0.3.1")
        #expect(information.build == "42")
        #expect(information.copyright == "Copyright © 2026 MoeKit")
    }

    @Test("Missing metadata does not invent a release or copyright")
    func missingMetadata() {
        let dictionaries: [[String: Any]?] = [nil, [:]]
        for dictionary in dictionaries {
            let information = AppInformation(infoDictionary: dictionary)
            #expect(information.version == nil)
            #expect(information.build == nil)
            #expect(information.copyright == nil)
        }
    }

    @Test("Blank, unresolved and wrong-type metadata stays unavailable")
    func invalidMetadata() {
        let information = AppInformation(infoDictionary: [
            "CFBundleShortVersionString": "$(MARKETING_VERSION)",
            "CFBundleVersion": 42,
            "NSHumanReadableCopyright": " \n "
        ])
        #expect(information.version == nil)
        #expect(information.build == nil)
        #expect(information.copyright == nil)
    }

    @Test("Metadata fields are independent and trim surrounding whitespace")
    func partialMetadata() {
        let versionOnly = AppInformation(infoDictionary: ["CFBundleShortVersionString": " 0.1.0\n"])
        #expect(versionOnly.version == "0.1.0")
        #expect(versionOnly.build == nil)
        let buildOnly = AppInformation(infoDictionary: ["CFBundleVersion": " 7 "])
        #expect(buildOnly.version == nil)
        #expect(buildOnly.build == "7")
    }

    @Test("Feedback and Star navigate to MoeKit without transmitting app or user data")
    func publicLinks() {
        #expect(MoeKitLinks.feedback.absoluteString == "https://github.com/cosZone/MoeKit/issues")
        #expect(MoeKitLinks.repository.absoluteString == "https://github.com/cosZone/MoeKit")
        for url in [MoeKitLinks.feedback, MoeKitLinks.repository] {
            #expect(url.scheme == "https")
            #expect(url.host == "github.com")
            #expect(url.query == nil)
            #expect(url.fragment == nil)
            #expect(url.user == nil)
            #expect(url.password == nil)
        }
    }
}
