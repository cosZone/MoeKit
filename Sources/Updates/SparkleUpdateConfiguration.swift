import Foundation

/// Only reviewed releases can activate the installer. Development, test and demo
/// processes never construct an updater, schedule requests, or modify its defaults.
struct SparkleUpdateConfiguration: Equatable, Sendable {
    static let feedURL = URL(string: "https://raw.githubusercontent.com/cosZone/MoeKit/updates/appcast.xml")!
    let publicKey: String
    let release: ReleaseVersion

    init?(info: [String: Any]?) {
        guard let info,
              info["SUFeedURL"] as? String == Self.feedURL.absoluteString,
              info["SURequireSignedFeed"] as? Bool == true,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              info["SUSignedFeedFailureExpirationInterval"] as? Int == 0,
              info["SUEnableSystemProfiling"] as? Bool == false,
              info["SUEnableJavaScript"] as? Bool == false,
              let key = info["SUPublicEDKey"] as? String,
              let bytes = Data(base64Encoded: key), bytes.count == 32,
              bytes.base64EncodedString() == key, bytes.contains(where: { $0 != 0 }),
              let release = ReleaseVersion.installed(in: info),
              let build = release.sparkleBuildVersion, info["CFBundleVersion"] as? String == build,
              let commit = info["MoeKitSourceCommit"] as? String,
              commit.count == 40, commit.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        self.publicKey = key
        self.release = release
    }

    static func processIsIsolated(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains("--demo") || arguments.contains("--disable-updates")
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCInjectBundleInto"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
