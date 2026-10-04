import AppKit
import Combine
import Observation
import Sparkle

struct AppUpdateSnapshot: Equatable {
    var canCheck = false
    var checksAutomatically = false
    var downloadsAutomatically = false
    var allowsAutomaticUpdates = false
    var lastChecked: Date?
}

@MainActor
protocol AppUpdateDriving: AnyObject {
    var snapshot: AppUpdateSnapshot { get }
    var didChange: ((AppUpdateSnapshot) -> Void)? { get set }
    var includePreviews: Bool { get set }
    func start() throws
    func check()
    func setAutomaticChecks(_ enabled: Bool)
    func setAutomaticDownloads(_ enabled: Bool)
}

/// One long-lived instance is shared by the application menu, status menu and
/// settings. Sparkle owns update scheduling, download, verification and install.
@MainActor @Observable
final class SparkleUpdateStore {
    private(set) var snapshot = AppUpdateSnapshot()
    private(set) var isStarted = false
    private(set) var failureMessage: String?
    private(set) var includePreviews: Bool
    @ObservationIgnored private let driver: (any AppUpdateDriving)?
    @ObservationIgnored private let defaults: UserDefaults?
    static let previewPreference = "MoeKit.includePreviewUpdates"

    init(configuration: SparkleUpdateConfiguration? = SparkleUpdateConfiguration(info: Bundle.main.infoDictionary),
         isolated: Bool = SparkleUpdateConfiguration.processIsIsolated(arguments: ProcessInfo.processInfo.arguments,
                                                                       environment: ProcessInfo.processInfo.environment),
         defaults: UserDefaults? = .standard,
         makeDriver: ((SparkleUpdateConfiguration, Bool) -> any AppUpdateDriving)? = nil) {
        self.defaults = defaults
        let previews = defaults?.object(forKey: Self.previewPreference) as? Bool
            ?? (configuration?.release.preview != nil)
        includePreviews = previews
        if let configuration, !isolated {
            driver = makeDriver?(configuration, previews)
                ?? SparkleUpdateDriver(configuration: configuration, includePreviews: previews)
        } else { driver = nil }
        driver?.didChange = { [weak self] value in self?.snapshot = value }
    }

    var isConfigured: Bool { driver != nil }
    var canCheck: Bool { isStarted && snapshot.canCheck }

    func start() {
        guard !isStarted, let driver else { return }
        do {
            try driver.start()
            isStarted = true
            snapshot = driver.snapshot
            failureMessage = nil
        } catch {
            failureMessage = String(localized: "Automatic updates could not start. You can still download a release from GitHub.")
        }
    }

    func check() { guard canCheck else { return }; driver?.check() }
    func setAutomaticChecks(_ enabled: Bool) {
        guard isStarted else { return }
        driver?.setAutomaticChecks(enabled)
        if let driver { snapshot = driver.snapshot }
    }
    func setAutomaticDownloads(_ enabled: Bool) {
        guard isStarted, snapshot.allowsAutomaticUpdates else { return }
        driver?.setAutomaticDownloads(enabled)
        if let driver { snapshot = driver.snapshot }
    }
    func setIncludePreviews(_ enabled: Bool) {
        guard isStarted, enabled != includePreviews else { return }
        includePreviews = enabled
        defaults?.set(enabled, forKey: Self.previewPreference)
        driver?.includePreviews = enabled
    }
}

@MainActor
private final class SparkleUpdateDriver: NSObject, AppUpdateDriving, SPUUpdaterDelegate {
    private let configuration: SparkleUpdateConfiguration
    private var controller: SPUStandardUpdaterController!
    private var observations = Set<AnyCancellable>()
    var didChange: ((AppUpdateSnapshot) -> Void)?
    var includePreviews: Bool {
        didSet { if oldValue != includePreviews { controller.updater.resetUpdateCycleAfterShortDelay() } }
    }

    init(configuration: SparkleUpdateConfiguration, includePreviews: Bool) {
        self.configuration = configuration
        self.includePreviews = includePreviews
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    }

    var snapshot: AppUpdateSnapshot {
        let updater = controller.updater
        return AppUpdateSnapshot(canCheck: updater.canCheckForUpdates,
            checksAutomatically: updater.automaticallyChecksForUpdates,
            downloadsAutomatically: updater.automaticallyDownloadsUpdates,
            allowsAutomaticUpdates: updater.allowsAutomaticUpdates, lastChecked: updater.lastUpdateCheckDate)
    }

    func start() throws {
        // Throws configuration failure without a misleading successful state.
        // Do not set automatic preferences here: Sparkle preserves user choices.
        try controller.updater.start()
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).sink { [weak self] _ in self?.refresh() }.store(in: &observations)
        updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] _ in self?.refresh() }.store(in: &observations)
        updater.publisher(for: \.automaticallyDownloadsUpdates).sink { [weak self] _ in self?.refresh() }.store(in: &observations)
        updater.publisher(for: \.allowsAutomaticUpdates).sink { [weak self] _ in self?.refresh() }.store(in: &observations)
        updater.publisher(for: \.lastUpdateCheckDate).sink { [weak self] _ in self?.refresh() }.store(in: &observations)
    }

    private func refresh() { didChange?(snapshot) }
    func check() { controller.checkForUpdates(nil) }
    func setAutomaticChecks(_ enabled: Bool) { controller.updater.automaticallyChecksForUpdates = enabled }
    func setAutomaticDownloads(_ enabled: Bool) { controller.updater.automaticallyDownloadsUpdates = enabled }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> { includePreviews ? ["preview"] : [] }
    func feedURLString(for updater: SPUUpdater) -> String? { SparkleUpdateConfiguration.feedURL.absoluteString }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
}
