// Original CI-only synthetic updater host. Never linked into MoeKit.
#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <signal.h>
#import <stdlib.h>
#import <limits.h>
#import <libproc.h>
#import <errno.h>
#import "fixture_json.h"

static NSDictionary *configuration;
static int rootFD = -1;
static int eventsFD = -1;
static struct stat pinnedRoot;
static NSString *caseName;
static struct stat pinnedEvents;

static BOOL intact(void) {
    struct stat pinned, named, markerInfo;
    NSString *root = configuration[@"FixtureRoot"];
    if (rootFD < 0 || fstat(rootFD, &pinned) || lstat(root.fileSystemRepresentation, &named) ||
        pinned.st_dev != pinnedRoot.st_dev || pinned.st_ino != pinnedRoot.st_ino ||
        named.st_dev != pinnedRoot.st_dev || named.st_ino != pinnedRoot.st_ino ||
        !S_ISDIR(named.st_mode) || (named.st_mode & 0777) != 0700 || named.st_uid != geteuid()) return NO;
    int marker = openat(rootFD, "owner-marker", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (marker < 0) return NO;
    char bytes[128] = {0};
    ssize_t count = read(marker, bytes, sizeof(bytes));
    BOOL valid = !fstat(marker, &markerInfo) && S_ISREG(markerInfo.st_mode) && markerInfo.st_nlink == 1 &&
        markerInfo.st_uid == geteuid() && count > 0 && count < (ssize_t)sizeof(bytes) &&
        [configuration[@"FixtureMarker"] isEqualToString:[[NSString alloc] initWithBytes:bytes length:(NSUInteger)count encoding:NSUTF8StringEncoding]];
    close(marker);
    int caseFD = openat(rootFD, caseName.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat caseInfo, installedInfo, app;
    if (caseFD < 0) return NO;
    int installedFD = openat(caseFD, "Installed", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    BOOL namespaceIntact = !fstat(caseFD, &caseInfo) && installedFD >= 0 && !fstat(installedFD, &installedInfo) &&
        (uint64_t)caseInfo.st_dev == [configuration[@"FixtureCaseDevice"] unsignedLongLongValue] &&
        caseInfo.st_ino == [configuration[@"FixtureCaseInode"] unsignedLongLongValue] &&
        (uint64_t)installedInfo.st_dev == [configuration[@"FixtureInstalledDevice"] unsignedLongLongValue] &&
        installedInfo.st_ino == [configuration[@"FixtureInstalledInode"] unsignedLongLongValue] &&
        caseInfo.st_uid == geteuid() && installedInfo.st_uid == geteuid() &&
        !fstatat(installedFD, "SparkleFixture.app", &app, AT_SYMLINK_NOFOLLOW) && S_ISDIR(app.st_mode) && app.st_uid == geteuid();
    close(caseFD); if (installedFD >= 0) close(installedFD);
    NSString *expected = [root stringByAppendingPathComponent:[caseName stringByAppendingPathComponent:@"Installed/SparkleFixture.app"]];
    char expectedPath[PATH_MAX], actualPath[PATH_MAX];
    struct stat eventInfo, namedEvent;
    NSString *eventPath = [root stringByAppendingPathComponent:[caseName stringByAppendingPathComponent:@"events.jsonl"]];
    BOOL logIntact = eventsFD < 0 || (!fstat(eventsFD, &eventInfo) && !lstat(eventPath.fileSystemRepresentation, &namedEvent) &&
        S_ISREG(namedEvent.st_mode) && namedEvent.st_nlink == 1 && namedEvent.st_uid == geteuid() &&
        eventInfo.st_dev == pinnedEvents.st_dev && eventInfo.st_ino == pinnedEvents.st_ino &&
        namedEvent.st_dev == pinnedEvents.st_dev && namedEvent.st_ino == pinnedEvents.st_ino);
    return valid && namespaceIntact && logIntact && realpath(expected.fileSystemRepresentation, expectedPath) &&
        realpath(NSBundle.mainBundle.bundlePath.fileSystemRepresentation, actualPath) && !strcmp(expectedPath, actualPath);
}

static void event(NSString *name, NSDictionary *extra) {
    if (!intact()) _exit(90);
    struct proc_bsdinfo process = {0};
    if (proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &process, sizeof(process)) != sizeof(process)) _exit(95);
    NSMutableDictionary *value = [@{@"event": name, @"version": configuration[@"CFBundleVersion"], @"case": caseName,
        @"pid": @(getpid()), @"uid": @(geteuid()), @"start_seconds": @(process.pbi_start_tvsec),
        @"start_microseconds": @(process.pbi_start_tvusec)} mutableCopy];
    [value addEntriesFromDictionary:extra ?: @{}];
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL];
    if (!data || write(eventsFD, data.bytes, data.length) != (ssize_t)data.length || write(eventsFD, "\n", 1) != 1 || fsync(eventsFD)) _exit(91);
}

static void finish(NSString *name, NSDictionary *extra) {
    event(name, extra);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
}

@interface FixtureDriver : NSObject <NSApplicationDelegate, SPUUpdaterDelegate, SPUUserDriver>
@property(nonatomic, strong) SPUUpdater *updater;
@property(nonatomic) uint64_t downloadedBytes;
@property(nonatomic) uint64_t expectedBytes;
@property(nonatomic, copy) void (^cancelDownload)(void);
@property(nonatomic) BOOL cancellationRequested;
@property(nonatomic, copy) void (^installReply)(SPUUserUpdateChoice);
- (void)awaitInstallerCheckpoint;
@end
@implementation FixtureDriver
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    event(@"launch", @{});
    NSUserDefaults *preferences = NSUserDefaults.standardUserDefaults; // unique synthetic bundle domain only
    if ([configuration[@"CFBundleVersion"] isEqualToString:@"2"]) {
        BOOL preserved = [[preferences stringForKey:@"FixturePreference"] isEqualToString:configuration[@"FixtureMarker"]] &&
            [preferences objectForKey:@"SUEnableAutomaticChecks"] != nil && ![preferences boolForKey:@"SUEnableAutomaticChecks"] &&
            [preferences objectForKey:@"SUAutomaticallyUpdate"] != nil && ![preferences boolForKey:@"SUAutomaticallyUpdate"];
        finish(@"relaunched", @{@"preferences_preserved": FixtureJSONBoolean(preserved),
            @"preference_marker_preserved": FixtureJSONBoolean([[preferences stringForKey:@"FixturePreference"] isEqualToString:configuration[@"FixtureMarker"]]),
            @"automatic_checks_stored": FixtureJSONBoolean([preferences objectForKey:@"SUEnableAutomaticChecks"] != nil),
            @"automatic_downloads_stored": FixtureJSONBoolean([preferences objectForKey:@"SUAutomaticallyUpdate"] != nil),
            @"automatic_checks": FixtureJSONBoolean([preferences boolForKey:@"SUEnableAutomaticChecks"]),
            @"automatic_downloads": FixtureJSONBoolean([preferences boolForKey:@"SUAutomaticallyUpdate"])});
        return;
    }
    [preferences setObject:configuration[@"FixtureMarker"] forKey:@"FixturePreference"];
    self.updater = [[SPUUpdater alloc] initWithHostBundle:NSBundle.mainBundle applicationBundle:NSBundle.mainBundle userDriver:self delegate:self];
    NSError *error = nil;
    if (![self.updater startUpdater:&error]) { finish(@"start_error", @{@"code": @(error.code)}); return; }
    // Sparkle ignores the download-preference setter while automatic updates
    // are unavailable. Exercise an explicit choice before disabling checks.
    // This completes synchronously before the next update-cycle run-loop turn.
    self.updater.automaticallyChecksForUpdates = YES;
    self.updater.automaticallyDownloadsUpdates = YES;
    self.updater.automaticallyDownloadsUpdates = NO;
    self.updater.automaticallyChecksForUpdates = NO;
    self.updater.sendsSystemProfile = NO;
    [preferences synchronize];
    BOOL explicitPreferences = [preferences objectForKey:@"SUEnableAutomaticChecks"] != nil &&
        [preferences objectForKey:@"SUAutomaticallyUpdate"] != nil &&
        ![preferences boolForKey:@"SUEnableAutomaticChecks"] && ![preferences boolForKey:@"SUAutomaticallyUpdate"];
    event(@"preferences_set", @{@"explicit_values_stored": FixtureJSONBoolean(explicitPreferences),
        @"automatic_checks": FixtureJSONBoolean(self.updater.automaticallyChecksForUpdates), @"automatic_downloads": FixtureJSONBoolean(self.updater.automaticallyDownloadsUpdates)});
    if (!explicitPreferences) { finish(@"preference_setup_error", @{}); return; }
    [self.updater checkForUpdates];
}
- (BOOL)updater:(SPUUpdater *)updater mayPerformUpdateCheck:(SPUUpdateCheck)kind error:(NSError **)error {
    (void)updater; (void)kind; (void)error;
    return intact();
}
- (NSSet<NSString *> *)allowedChannelsForUpdater:(SPUUpdater *)updater {
    (void)updater;
    return [configuration[@"FixturePreviewAllowed"] boolValue] ? [NSSet setWithObject:@"preview"] : [NSSet set];
}
- (NSArray<NSString *> *)allowedSystemProfileKeysForUpdater:(SPUUpdater *)updater { (void)updater; return @[]; }
- (void)updater:(SPUUpdater *)updater didFinishLoadingAppcast:(SUAppcast *)appcast {
    (void)updater;
    BOOL verified = appcast.items.count > 0;
    for (SUAppcastItem *item in appcast.items) verified = verified && item.signingValidationStatus == SPUAppcastSigningValidationStatusSucceeded;
    event(@"feed_loaded", @{@"signature_verified": FixtureJSONBoolean(verified)});
}
- (void)updater:(SPUUpdater *)updater didExtractUpdate:(SUAppcastItem *)item {
    (void)updater; (void)item; // In Sparkle 2.10.0 this callback means installer startup completed,
    // not successful archive validation or extraction.
    event(@"installer_started", @{});
}
- (void)updater:(SPUUpdater *)updater willInstallUpdate:(SUAppcastItem *)item {
    (void)updater; (void)item;
    if (!intact()) _exit(92);
    event(@"will_install", @{});
}
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply {
    (void)request;
    reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:NO automaticUpdateDownloading:@NO sendSystemProfile:NO]);
}
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation { (void)cancellation; event(@"checking", @{}); }
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    (void)state;
    event(@"found", @{@"offered_version": item.versionString, @"signature_verified": FixtureJSONBoolean(item.signingValidationStatus == SPUAppcastSigningValidationStatusSucceeded)});
    if (!intact()) _exit(93);
    reply(SPUUserUpdateChoiceInstall);
}
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data { (void)data; }
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error { (void)error; }
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))reply { reply(); finish(@"not_found", @{@"code": @(error.code)}); }
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))reply {
    NSMutableArray *codes = [NSMutableArray array];
    for (NSError *current = error; current && codes.count < 8; current = current.userInfo[NSUnderlyingErrorKey])
        [codes addObject:@{@"domain": current.domain, @"code": @(current.code)}];
    reply(); finish(@"error", @{@"errors": codes, @"download_bytes": @(self.downloadedBytes)});
}
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation {
    self.cancelDownload = cancellation;
    event(@"download_started", @{});
}
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length { self.expectedBytes = length; }
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {
    self.downloadedBytes += length;
    if ([caseName isEqualToString:@"cancel"] && !self.cancellationRequested && self.cancelDownload &&
        self.downloadedBytes > 0 && self.expectedBytes > self.downloadedBytes) {
        self.cancellationRequested = YES;
        event(@"cancel_requested", @{@"download_bytes": @(self.downloadedBytes), @"expected_bytes": @(self.expectedBytes)});
        void (^cancel)(void) = self.cancelDownload;
        self.cancelDownload = nil;
        cancel();
    }
}
- (void)userDidCancelDownload:(SPUUpdater *)updater {
    (void)updater;
    finish(@"cancelled", @{@"download_bytes": @(self.downloadedBytes), @"expected_bytes": @(self.expectedBytes),
        @"cancellation_requested": FixtureJSONBoolean(self.cancellationRequested)});
}
- (void)showDownloadDidStartExtractingUpdate { event(@"extraction_ui_started", @{@"download_bytes": @(self.downloadedBytes)}); }
- (void)showExtractionReceivedProgress:(double)progress { (void)progress; }
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply {
    if (!intact()) _exit(94);
    event(@"ready_to_install", @{@"download_bytes": @(self.downloadedBytes)});
    self.installReply = reply;
    [self awaitInstallerCheckpoint];
}
- (void)awaitInstallerCheckpoint {
    if (!intact()) _exit(96);
    int caseFD = openat(rootFD, caseName.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat directory;
    if (caseFD < 0 || fstat(caseFD, &directory) || directory.st_ino != [configuration[@"FixtureCaseInode"] unsignedLongLongValue] ||
        (uint64_t)directory.st_dev != [configuration[@"FixtureCaseDevice"] unsignedLongLongValue]) _exit(97);
    int fd = openat(caseFD, "install-ack", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    int savedErrno = errno;
    close(caseFD);
    if (fd < 0) {
        if (savedErrno != ENOENT) _exit(98);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{ [self awaitInstallerCheckpoint]; });
        return;
    }
    struct stat info;
    char bytes[33] = {0};
    ssize_t count = read(fd, bytes, sizeof(bytes));
    BOOL valid = !fstat(fd, &info) && S_ISREG(info.st_mode) && info.st_uid == geteuid() && info.st_nlink == 1 && count == 32 &&
        [configuration[@"FixtureMarker"] isEqualToString:[[NSString alloc] initWithBytes:bytes length:32 encoding:NSUTF8StringEncoding]];
    close(fd);
    if (!valid || !self.installReply) _exit(99);
    event(@"installer_checkpoint_accepted", @{});
    void (^reply)(SPUUserUpdateChoice) = self.installReply;
    self.installReply = nil;
    reply(SPUUserUpdateChoiceInstall);
}
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry {
    (void)terminated; (void)retry; event(@"installing", @{});
}
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))reply { (void)relaunched; reply(); }
- (void)dismissUpdateInstallation { event(@"dismissed", @{}); }
@end

int main(void) {
    @autoreleasepool {
        configuration = NSBundle.mainBundle.infoDictionary;
        caseName = configuration[@"FixtureCase"];
        NSString *identifier = NSBundle.mainBundle.bundleIdentifier;
        NSArray *allowedCases = @[@"valid", @"tampered-feed", @"tampered-archive", @"wrong-key", @"invalid-archive", @"cancel",
            @"equal-version", @"older-version", @"preview-filtered", @"preview-allowed"];
        NSString *marker = configuration[@"FixtureMarker"];
        if (![marker isKindOfClass:NSString.class] || marker.length != 32 ||
            [marker rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location != NSNotFound ||
            ![caseName isKindOfClass:NSString.class] || ![allowedCases containsObject:caseName]) return 80;
        NSString *exactIdentifier = [NSString stringWithFormat:@"org.moekit.CIFixture.r%@.%@", marker,
            [caseName stringByReplacingOccurrencesOfString:@"-" withString:@""]];
        if (![identifier isEqualToString:exactIdentifier]) return 80;
        // LaunchServices relaunch need not inherit the CI environment. The Python
        // entrypoint gates hosted CI; this host instead requires its signed,
        // generated fixture configuration and pinned private namespace.
        if (getuid() != geteuid() || geteuid() == 0 || ![identifier hasPrefix:@"org.moekit.CIFixture."] ||
            ![caseName isKindOfClass:NSString.class] || ![configuration[@"FixtureCI"] boolValue] ||
            ![[configuration[@"FixtureRoot"] lastPathComponent] hasPrefix:@"moekit-sparkle-"]) return 80;
        NSString *root = configuration[@"FixtureRoot"];
        rootFD = open(root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (rootFD < 0 || fstat(rootFD, &pinnedRoot) ||
            (uint64_t)pinnedRoot.st_dev != [configuration[@"FixtureDevice"] unsignedLongLongValue] ||
            pinnedRoot.st_ino != [configuration[@"FixtureInode"] unsignedLongLongValue] || !intact()) return 81;
        NSString *events = [root stringByAppendingPathComponent:[caseName stringByAppendingPathComponent:@"events.jsonl"]];
        eventsFD = open(events.fileSystemRepresentation, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC);
        struct stat log;
        if (eventsFD < 0 || fstat(eventsFD, &log) || !S_ISREG(log.st_mode) || log.st_nlink != 1 || log.st_uid != geteuid() ||
            (uint64_t)log.st_dev != [configuration[@"FixtureEventDevice"] unsignedLongLongValue] ||
            log.st_ino != [configuration[@"FixtureEventInode"] unsignedLongLongValue]) return 82;
        pinnedEvents = log;
        sigset_t mask; sigemptyset(&mask); sigaddset(&mask, SIGALRM); sigprocmask(SIG_UNBLOCK, &mask, NULL);
        signal(SIGALRM, SIG_DFL); alarm(110); // no name/PID/group cleanup signal is ever needed
        NSApplication *application = NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        FixtureDriver *driver = [FixtureDriver new];
        application.delegate = driver;
        [application run];
        close(eventsFD); close(rootFD);
    }
    return 0;
}
