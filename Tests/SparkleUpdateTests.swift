import Foundation
import Testing
import Sparkle
@testable import MoeKit

@MainActor
struct SparkleUpdateTests {
    static var info: [String: Any] {
        ["SUFeedURL": SparkleUpdateConfiguration.feedURL.absoluteString,
         // RFC 8032 public test vector. Never a production signing identity.
         "SUPublicEDKey": "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=",
         "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true,
         "SUSignedFeedFailureExpirationInterval": 0, "SUEnableSystemProfiling": false,
         "SUEnableJavaScript": false, "MoeKitPreviewVersion": "0.1.0-preview.10",
         "CFBundleVersion": "2.0.10", "MoeKitSourceCommit": String(repeating: "a", count: 40)]
    }

    @Test func releaseBuildNumbersOrderNumericallyWithoutWorkflowCounters() {
        #expect(ReleaseVersion("0.1.0-preview.9")?.sparkleBuildVersion == "2.0.9")
        #expect(ReleaseVersion("0.1.0-preview.10")?.sparkleBuildVersion == "2.0.10")
        #expect(ReleaseVersion("0.1.0")?.sparkleBuildVersion == "2.0.99")
        #expect(ReleaseVersion("0.1.1-preview.1")?.sparkleBuildVersion == "2.1.1")
        #expect(ReleaseVersion("1.0.0-preview.1")?.sparkleBuildVersion == "101.0.1")
        let comparator = SUStandardVersionComparator()
        for (old, new) in [("2.0.9", "2.0.10"), ("2.0.10", "2.0.99"), ("2.0.99", "2.1.1"), ("2.99.99", "3.0.1")] {
            #expect(comparator.compareVersion(old, toVersion: new) == .orderedAscending)
            #expect(comparator.compareVersion(new, toVersion: old) == .orderedDescending)
            #expect(comparator.compareVersion(old, toVersion: old) == .orderedSame)
        }
        for version in ["0.1.0-preview.0", "0.1.0-preview.99", "99.0.0", "0.100.0", "0.1.100"] {
            #expect(ReleaseVersion(version)?.sparkleBuildVersion == nil)
        }
    }

    @Test func configurationFailsClosed() {
        #expect(SparkleUpdateConfiguration(info: Self.info) != nil)
        for key in Self.info.keys {
            var invalid = Self.info; invalid.removeValue(forKey: key)
            #expect(SparkleUpdateConfiguration(info: invalid) == nil)
        }
        for key in ["", "$(SPARKLE_PUBLIC_ED_KEY)", String(repeating: "A", count: 44),
                    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", Self.info["SUPublicEDKey"] as! String + "\n"] {
            var invalid = Self.info; invalid["SUPublicEDKey"] = key
            #expect(SparkleUpdateConfiguration(info: invalid) == nil)
        }
        for field in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"] {
            var invalid = Self.info; invalid[field] = false
            #expect(SparkleUpdateConfiguration(info: invalid) == nil)
        }
        for url in ["http://raw.githubusercontent.com/cosZone/MoeKit/updates/appcast.xml",
                    "https://example.com/appcast.xml", SparkleUpdateConfiguration.feedURL.absoluteString + "?token=x"] {
            var invalid = Self.info; invalid["SUFeedURL"] = url
            #expect(SparkleUpdateConfiguration(info: invalid) == nil)
        }
    }

    @Test func isolatedProcessesNeverConstructStartOrChangeUpdater() throws {
        var constructed = 0
        let store = SparkleUpdateStore(configuration: try #require(SparkleUpdateConfiguration(info: Self.info)),
            isolated: true, defaults: nil, makeDriver: { _, _ in constructed += 1; return FixtureUpdateDriver() })
        store.start(); store.check(); store.setAutomaticChecks(true); store.setAutomaticDownloads(true)
        #expect(constructed == 0 && !store.isConfigured && !store.isStarted && !store.canCheck)
        #expect(SparkleUpdateConfiguration.processIsIsolated(arguments: ["app", "--demo"], environment: [:]))
        #expect(SparkleUpdateConfiguration.processIsIsolated(arguments: ["app", "--disable-updates"], environment: [:]))
        #expect(SparkleUpdateConfiguration.processIsIsolated(arguments: ["app"], environment: ["XCTestBundlePath": "fixture"]))
    }

    @Test func sharedControllerKeepsPreferencesAndStartsOnlyOnce() throws {
        let driver = FixtureUpdateDriver()
        driver.snapshot = .init(canCheck: true, checksAutomatically: false, downloadsAutomatically: true,
                                allowsAutomaticUpdates: true)
        let store = SparkleUpdateStore(configuration: try #require(SparkleUpdateConfiguration(info: Self.info)),
            isolated: false, defaults: nil, makeDriver: { _, _ in driver })
        store.start(); store.start()
        #expect(driver.starts == 1 && store.isStarted && store.canCheck)
        #expect(driver.settingWrites == 0)
        #expect(!store.snapshot.checksAutomatically && store.snapshot.downloadsAutomatically)
        store.check(); store.check()
        #expect(driver.checks == 2)
        driver.snapshot.canCheck = false; driver.didChange?(driver.snapshot)
        store.check()
        #expect(driver.checks == 2 && !store.canCheck)
        store.setAutomaticChecks(true); store.setAutomaticDownloads(false)
        #expect(driver.settingWrites == 2)
        #expect(store.snapshot.checksAutomatically && !store.snapshot.downloadsAutomatically)
    }

    @Test func failedStartIsVisibleAndCanRetryWithoutChecking() throws {
        let driver = FixtureUpdateDriver(); driver.failStart = true
        let store = SparkleUpdateStore(configuration: try #require(SparkleUpdateConfiguration(info: Self.info)),
            isolated: false, defaults: nil, makeDriver: { _, _ in driver })
        store.start(); store.check()
        #expect(!store.isStarted && store.failureMessage != nil && driver.checks == 0)
        driver.failStart = false; store.start()
        #expect(store.isStarted && store.failureMessage == nil)
    }

    @Test func channelsPersistIndependentlyAndRespectInstalledRelease() throws {
        let name = "MoeKit-updater-fixture-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("fixture", forKey: "unrelated")
        let configuration = try #require(SparkleUpdateConfiguration(info: Self.info))
        let driver = FixtureUpdateDriver()
        let store = SparkleUpdateStore(configuration: configuration, isolated: false, defaults: defaults,
                                       makeDriver: { _, preview in driver.includePreviews = preview; return driver })
        #expect(store.includePreviews && driver.includePreviews)
        store.start()
        driver.snapshot.sessionInProgress = true; driver.didChange?(driver.snapshot)
        store.setIncludePreviews(false)
        #expect(driver.includePreviews)
        driver.snapshot.sessionInProgress = false; driver.didChange?(driver.snapshot)
        store.setIncludePreviews(false)
        #expect(!driver.includePreviews)
        let relaunched = SparkleUpdateStore(configuration: configuration, isolated: false, defaults: defaults,
                                            makeDriver: { _, _ in FixtureUpdateDriver() })
        #expect(!relaunched.includePreviews && defaults.string(forKey: "unrelated") == "fixture")
        #expect(defaults.persistentDomain(forName: name)?.count == 2)
        var stableInfo = Self.info
        stableInfo.removeValue(forKey: "MoeKitPreviewVersion"); stableInfo["MoeKitReleaseVersion"] = "0.1.0"
        stableInfo["CFBundleVersion"] = "2.0.99"
        let stable = SparkleUpdateStore(configuration: try #require(SparkleUpdateConfiguration(info: stableInfo)),
                                       isolated: false, defaults: nil, makeDriver: { _, _ in FixtureUpdateDriver() })
        #expect(!stable.includePreviews)
    }
}

@MainActor
private final class FixtureUpdateDriver: AppUpdateDriving {
    var snapshot = AppUpdateSnapshot(canCheck: true, allowsAutomaticUpdates: true)
    var didChange: ((AppUpdateSnapshot) -> Void)?
    var includePreviews = false
    var starts = 0, checks = 0, settingWrites = 0
    var failStart = false
    func start() throws { starts += 1; if failStart { throw CocoaError(.fileReadUnknown) } }
    func check() { checks += 1 }
    func setAutomaticChecks(_ enabled: Bool) { settingWrites += 1; snapshot.checksAutomatically = enabled }
    func setAutomaticDownloads(_ enabled: Bool) { settingWrites += 1; snapshot.downloadsAutomatically = enabled }
}

@MainActor
struct UpdateInstallationSafetyTests {
    @Test func busyAdaptersBlockTerminationAndReleaseTheirBlockWhenFinished() {
        let safety = UpdateInstallationSafety()
        let fixture = UpdateActivityFixture()
        #expect(safety.canTerminate)
        fixture.blocksAppUpdate = true; safety.changed(fixture)
        #expect(!safety.canTerminate)
        fixture.blocksAppUpdate = false; safety.changed(fixture)
        #expect(safety.canTerminate)
    }

    @Test func registryDoesNotKeepClosedOperationsAlive() {
        let safety = UpdateInstallationSafety()
        var fixture: UpdateActivityFixture? = UpdateActivityFixture()
        fixture?.blocksAppUpdate = true; safety.changed(fixture!)
        #expect(!safety.canTerminate)
        fixture = nil
        #expect(safety.canTerminate)
    }
}

@MainActor private final class UpdateActivityFixture: AppUpdateBlocking {
    var blocksAppUpdate = false
}
