// Original read-only, CI-only lifetime probe. Never linked into MoeKit.
// A negative result is scoped to this user/bootstrap namespace, not global idle.
#import <AppKit/AppKit.h>
#import <libproc.h>
#import <mach/mach.h>
#import <servers/bootstrap.h>
#import <sys/stat.h>
#import <sys/proc.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <stdlib.h>
#import <limits.h>
#import <time.h>
#import "probe_policy.h"
#import "fixture_json.h"

// POSIX physical paths are identity inputs; Foundation standardization may
// intentionally remove /private and must not be used for identity comparisons.
static NSString *physicalPath(NSString *path) {
    if (![path hasPrefix:@"/"] || [path lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >= PATH_MAX) { errno = EINVAL; return nil; }
    char resolved[PATH_MAX];
    return realpath(path.fileSystemRepresentation, resolved) ? [NSString stringWithUTF8String:resolved] : nil;
}
static BOOL parseIdentity(const char *value, uint64_t *result) {
    if (!value[0]) return NO;
    for (const char *p = value; *p; p++) if (*p < '0' || *p > '9') return NO;
    errno = 0; char *end = NULL;
    unsigned long long number = strtoull(value, &end, 10);
    if (errno || !end || *end) return NO;
    *result = number; return YES;
}
static BOOL sameRoot(struct stat a, struct stat b) {
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino && S_ISDIR(a.st_mode) && S_ISDIR(b.st_mode) &&
        a.st_uid == geteuid() && b.st_uid == geteuid() && (a.st_mode & 0777) == 0700 && (b.st_mode & 0777) == 0700;
}
static struct FixtureProcess processValue(struct proc_bsdinfo value) {
    return (struct FixtureProcess){ .pid = value.pbi_pid, .euid = value.pbi_uid, .ruid = value.pbi_ruid,
        .seconds = value.pbi_start_tvsec, .microseconds = value.pbi_start_tvusec, .zombie = value.pbi_status == SZOMB };
}
static enum FixtureLookup lookupProcess(pid_t pid, struct FixtureProcess *value, int *error) {
    struct proc_bsdinfo info = {0}; errno = 0;
    int size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 1, &info, sizeof(info));
    *error = errno;
    if (size == (int)sizeof(info) && info.pbi_pid == (uint32_t)pid) { *value = processValue(info); return FixtureLookupPresent; }
    return size <= 0 && *error == ESRCH ? FixtureLookupGone : FixtureLookupUnknown;
}
static struct FixtureProcess entryValue(NSDictionary *entry) {
    return (struct FixtureProcess){ .pid = [entry[@"pid"] unsignedIntValue], .euid = [entry[@"uid"] unsignedIntValue],
        .ruid = [entry[@"uid"] unsignedIntValue], .seconds = [entry[@"start_seconds"] unsignedLongLongValue],
        .microseconds = [entry[@"start_microseconds"] unsignedLongLongValue], .zombie = false };
}
static NSString *identityKey(struct FixtureProcess value) {
    return [NSString stringWithFormat:@"%u:%llu:%llu", value.pid,
            (unsigned long long)value.seconds, (unsigned long long)value.microseconds];
}
static NSDictionary *knownEntry(NSDictionary *known, struct FixtureProcess first, struct FixtureProcess second,
                                enum FixtureLookup firstLookup, enum FixtureLookup secondLookup) {
    NSDictionary *entry = firstLookup == FixtureLookupPresent ? known[identityKey(first)] : nil;
    return entry ?: (secondLookup == FixtureLookupPresent ? known[identityKey(second)] : nil);
}
enum FixturePathStage { FixturePathNotRead, FixturePathKernel, FixturePathEncoding,
    FixturePathPhysical, FixturePathParent, FixturePathLeaf };
static BOOL monotonicNanos(uint64_t *value) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) || now.tv_sec < 0 || now.tv_nsec < 0 || now.tv_nsec >= 1000000000L ||
        (uint64_t)now.tv_sec > (UINT64_MAX - (uint64_t)now.tv_nsec) / 1000000000ULL) return NO;
    *value = (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec;
    return YES;
}
static enum FixtureScope executableScope(pid_t pid, NSString *root, NSString *cache,
                                         NSString **physical, int *error, enum FixturePathStage *stage) {
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0}; errno = 0;
    *stage = FixturePathKernel;
    int length = proc_pidpath(pid, path, sizeof(path));
    *error = errno;
    if (length <= 0) return FixtureScopeUnknown;
    *stage = FixturePathEncoding;
    if (length >= (int)sizeof(path)) { *error = EOVERFLOW; return FixtureScopeUnknown; }
    NSString *executable = [NSString stringWithUTF8String:path];
    if (!executable) { *error = EILSEQ; return FixtureScopeUnknown; }
    *stage = FixturePathPhysical;
    errno = 0;
    *physical = physicalPath(executable);
    int resolutionError = errno;
    if (*physical) {
        *error = 0;
        return FixturePathScope((*physical).fileSystemRepresentation, root.fileSystemRepresentation, cache.fileSystemRepresentation);
    }
    *error = resolutionError;
    // Only a physically resolved outside parent plus an affirmatively missing
    // leaf can exclude a disappeared outside executable. A raw root/cache or
    // /var alias candidate, an unreadable parent or an ambiguous path stays unknown.
    enum FixtureScope namedScope = FixturePathScope(executable.fileSystemRepresentation,
        root.fileSystemRepresentation, cache.fileSystemRepresentation);
    NSString *systemAlias = [executable hasPrefix:@"/var/"] ? [@"/private" stringByAppendingString:executable] : executable;
    enum FixtureScope aliasScope = FixturePathScope(systemAlias.fileSystemRepresentation,
        root.fileSystemRepresentation, cache.fileSystemRepresentation);
    if (resolutionError == ENOENT && namedScope == FixtureScopeOutside && aliasScope == FixtureScopeOutside) {
        *stage = FixturePathParent;
        errno = 0;
        NSString *parent = physicalPath(executable.stringByDeletingLastPathComponent);
        *error = errno;
        if (!parent) return FixtureScopeUnknown;
        NSString *candidate = [parent stringByAppendingPathComponent:executable.lastPathComponent];
        struct stat info; errno = 0;
        *stage = FixturePathLeaf;
        int result = lstat(executable.fileSystemRepresentation, &info);
        *error = errno;
        if (result == -1 && *error == ENOENT &&
            FixturePathScope(candidate.fileSystemRepresentation, root.fileSystemRepresentation, cache.fileSystemRepresentation) == FixtureScopeOutside)
            return FixtureScopeOutside;
    }
    return FixtureScopeUnknown;
}
static void processDiagnostic(const char *phase, enum FixtureDecision decision,
                              struct FixtureProcess first, struct FixtureProcess second,
                              enum FixtureLookup firstLookup, enum FixtureLookup secondLookup,
                              enum FixtureScope firstScope, enum FixtureScope secondScope,
                              BOOL known, int firstError, int secondError, int firstPathError, int secondPathError,
                              enum FixturePathStage firstStage, enum FixturePathStage secondStage) {
    // Fixed categories and booleans only: no ambient PID, executable, arguments
    // or environment values are printed.
    fprintf(stderr, "Fixture process observation: phase=%s decision=%d lookup=%d,%d scope=%d,%d known=%d identity_equal=%d uid_equal=%d,%d errno=%d,%d path_errno=%d,%d path_stage=%d,%d zombie=%d,%d\n",
        phase, decision, firstLookup, secondLookup, firstScope, secondScope, known,
        FixtureSameIdentity(first, second), first.euid == geteuid() && first.ruid == getuid(),
        second.euid == geteuid() && second.ruid == getuid(), firstError, secondError, firstPathError, secondPathError,
        firstStage, secondStage, first.zombie, second.zombie);
}
static enum FixtureDecision observeProcess(pid_t pid, NSDictionary *known, NSString *root, NSString *cache,
                                           NSDictionary **entry, struct FixtureProcess *classified,
                                           struct FixturePathRetryBudget *budget) {
    struct FixturePathRetryState retry = {0};
    for (;;) {
        struct FixtureProcess first = {0}, second = {0};
        int firstError = 0, secondError = 0, firstPathError = 0, secondPathError = 0;
        enum FixturePathStage firstStage = FixturePathNotRead, secondStage = FixturePathNotRead;
        enum FixtureLookup firstLookup = lookupProcess(pid, &first, &firstError);
        NSString *firstPath = nil, *secondPath = nil;
        enum FixtureScope firstScope = FixtureScopeUnknown, secondScope = FixtureScopeUnknown;
        if (firstLookup == FixtureLookupPresent && !first.zombie) {
            firstScope = executableScope(pid, root, cache, &firstPath, &firstPathError, &firstStage);
            secondScope = executableScope(pid, root, cache, &secondPath, &secondPathError, &secondStage);
        }
        enum FixtureLookup secondLookup = lookupProcess(pid, &second, &secondError);
        *classified = second;
        NSDictionary *previous = knownEntry(known, first, second, firstLookup, secondLookup);
        struct FixtureProcess expected = previous ? entryValue(previous) : (struct FixtureProcess){0};
        enum FixtureDecision decision = FixtureClassify(first, second, firstLookup, secondLookup, firstScope, secondScope,
                                                         geteuid(), previous ? &expected : NULL);
        uint64_t now = 0;
        if (!monotonicNanos(&now)) return FixtureDecisionUnknown;
        enum FixturePathRetryAction action = FixturePathRetryObserve(&retry, budget, first, second, firstLookup, secondLookup,
            firstScope, secondScope, previous ? &expected : NULL, decision,
            firstStage == FixturePathKernel && firstPathError == ESRCH,
            secondStage == FixturePathKernel && secondPathError == ESRCH, geteuid(), now);
        if (action == FixturePathRetryAgain) {
            processDiagnostic("path-resample", decision, first, second, firstLookup, secondLookup, firstScope, secondScope,
                previous != nil, firstError, secondError, firstPathError, secondPathError, firstStage, secondStage);
            // The unresolved anchor remains local to this invocation. It never
            // enters the trusted-owned map and cannot grant idle or install-ack.
            struct timespec delay = { .tv_sec = 0, .tv_nsec = (long)FIXTURE_PATH_RETRY_DELAY_NS };
            if (nanosleep(&delay, NULL)) {
                fprintf(stderr, "Fixture path resample sleep interrupted\n"); return FixtureDecisionUnknown;
            }
            if (!monotonicNanos(&now) || !FixturePathRetryWithinBudget(budget, now)) {
                fprintf(stderr, "Fixture path resample invocation deadline invalid or exhausted\n"); return FixtureDecisionUnknown;
            }
            budget->last_ns = now;
            continue;
        }
        if (action == FixturePathRetryRefuse) {
            decision = FixtureDecisionUnknown;
            if (retry.pending) fprintf(stderr, "Fixture unresolved path resample refused; remaining_delays=%u\n", budget->remaining);
        }
        if (decision == FixtureDecisionOwned) {
            NSString *path = secondPath ?: firstPath;
            NSString *role = previous ? previous[@"role"] :
                [path hasSuffix:@"/Sparkle.framework/Versions/B/Autoupdate"] ? @"installer" :
                [path hasSuffix:@"/Updater.app/Contents/MacOS/Updater"] ? @"progress-agent" : @"fixture-process";
            *entry = @{@"pid": @(second.pid), @"uid": @(second.euid), @"start_seconds": @(second.seconds),
                @"start_microseconds": @(second.microseconds), @"role": role,
                @"scope": previous ? @"tracked-identity" : [path hasPrefix:[root stringByAppendingString:@"/"]] ? @"owned-root" : @"exact-fixture-cache"};
        } else if (decision == FixtureDecisionUnknown || decision == FixtureDecisionChanged) {
            processDiagnostic(retry.pending ? "unresolved-path" : "scan", decision, first, second, firstLookup, secondLookup, firstScope, secondScope,
                previous != nil, firstError, secondError, firstPathError, secondPathError, firstStage, secondStage);
        }
        return decision;
    }
}
static int fail(NSString *reason) {
    fprintf(stderr, "Fixture lifetime probe unknown: %s\n", reason.UTF8String);
    return 2;
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 7 || !FixtureNormalUser(getuid(), geteuid()) || ![NSProcessInfo.processInfo.environment[@"GITHUB_ACTIONS"] isEqualToString:@"true"] ||
            ![NSProcessInfo.processInfo.environment[@"RUNNER_ENVIRONMENT"] isEqualToString:@"github-hosted"]) return fail(@"CI gate");
        uint64_t invocationStart = 0;
        if (!monotonicNanos(&invocationStart)) return fail(@"monotonic clock");
        struct FixturePathRetryBudget pathRetryBudget = FixtureMakePathRetryBudget(invocationStart);
        NSString *namedRoot = [NSString stringWithUTF8String:argv[1]], *identifier = [NSString stringWithUTF8String:argv[2]];
        NSString *marker = [NSString stringWithUTF8String:argv[3]];
        NSRegularExpression *markerPattern = [NSRegularExpression regularExpressionWithPattern:@"^[a-f0-9]{32}$" options:0 error:NULL];
        NSRegularExpression *identifierPattern = [NSRegularExpression regularExpressionWithPattern:@"^org\\.moekit\\.CIFixture\\.r[a-f0-9]{32}\\.[a-z]+$" options:0 error:NULL];
        if ([markerPattern numberOfMatchesInString:marker options:0 range:NSMakeRange(0, marker.length)] != 1) return fail(@"marker syntax");
        if ([identifierPattern numberOfMatchesInString:identifier options:0 range:NSMakeRange(0, identifier.length)] != 1 ||
            ![identifier hasPrefix:[@"org.moekit.CIFixture.r" stringByAppendingFormat:@"%@.", marker]]) return fail(@"bundle identifier");
        NSString *caseName = nil;
        for (NSString *candidate in @[@"valid", @"tampered-feed", @"tampered-archive", @"wrong-key", @"invalid-archive", @"cancel",
            @"equal-version", @"older-version", @"preview-filtered", @"preview-allowed"]) {
            if ([identifier hasSuffix:[@"." stringByAppendingString:[candidate stringByReplacingOccurrencesOfString:@"-" withString:@""]]]) caseName = candidate;
        }
        if (!caseName) return fail(@"case identifier");
        uint64_t expectedDevice = 0, expectedInode = 0;
        if (!parseIdentity(argv[4], &expectedDevice) || !parseIdentity(argv[5], &expectedInode)) return fail(@"root identity syntax");
        NSString *root = physicalPath(namedRoot);
        if (!root || ![root.lastPathComponent hasPrefix:@"moekit-sparkle-"]) return fail(@"root physical path");
        struct stat before, after, named, pinned;
        if (lstat(root.fileSystemRepresentation, &before) || lstat(namedRoot.fileSystemRepresentation, &named) ||
            !sameRoot(before, named) || (uint64_t)before.st_dev != expectedDevice || (uint64_t)before.st_ino != expectedInode)
            return fail(@"root identity");
        int rootFD = open(namedRoot.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (rootFD < 0 || fstat(rootFD, &pinned) || !sameRoot(before, pinned)) return fail(@"root descriptor");
        int markerFD = openat(rootFD, "owner-marker", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        char markerBytes[33] = {0}; struct stat markerInfo;
        BOOL markerValid = markerFD >= 0 && !fstat(markerFD, &markerInfo) && S_ISREG(markerInfo.st_mode) &&
            markerInfo.st_nlink == 1 && markerInfo.st_uid == geteuid() && read(markerFD, markerBytes, sizeof(markerBytes)) == 32 &&
            [marker isEqualToString:[[NSString alloc] initWithBytes:markerBytes length:32 encoding:NSUTF8StringEncoding]];
        if (markerFD >= 0) close(markerFD);
        if (!markerValid) return fail(@"owner marker");
        NSURL *cacheURL = [NSFileManager.defaultManager URLForDirectory:NSCachesDirectory inDomain:NSUserDomainMask
            appropriateForURL:nil create:NO error:NULL];
        NSString *cacheParent = physicalPath(cacheURL.path);
        if (!cacheParent) return fail(@"cache parent physical path");
        NSString *cache = [cacheParent stringByAppendingPathComponent:identifier];
        NSData *trackedData = [[NSString stringWithUTF8String:argv[6]] dataUsingEncoding:NSUTF8StringEncoding];
        NSArray *tracked = [NSJSONSerialization JSONObjectWithData:trackedData options:0 error:NULL];
        if (![tracked isKindOfClass:NSArray.class] || tracked.count > 32) return fail(@"tracked identity input");
        for (NSDictionary *entry in tracked) {
            if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"pid"] isKindOfClass:NSNumber.class] ||
                ![entry[@"uid"] isKindOfClass:NSNumber.class] || [entry[@"uid"] unsignedIntValue] != geteuid() ||
                ![entry[@"start_seconds"] isKindOfClass:NSNumber.class] || ![entry[@"start_microseconds"] isKindOfClass:NSNumber.class] ||
                ![entry[@"role"] isKindOfClass:NSString.class]) return fail(@"tracked identity shape");
        }
        NSMutableDictionary<NSString *, NSDictionary *> *observed = [NSMutableDictionary dictionary];
        for (NSDictionary *entry in tracked) observed[identityKey(entryValue(entry))] = entry;
        NSMutableDictionary<NSNumber *, NSValue *> *finalInventory = [NSMutableDictionary dictionary];
        NSDictionary<NSString *, NSDictionary *> *previousPass = @{};
        NSDictionary<NSString *, NSDictionary *> *lastPass = @{};
        pid_t pids[16384];
        // Each pass classifies ownership before imposing fixture credentials.
        // New outside processes are harmless; an owned birth in the final pass
        // is inconclusive. No first-pass-only role can authorize installation.
        for (int pass = 0; pass < 3; pass++) {
            [finalInventory removeAllObjects];
            int bytes = proc_listpids(PROC_UID_ONLY, geteuid(), pids, sizeof(pids));
            if (bytes <= 0 || bytes >= (int)sizeof(pids) || bytes % (int)sizeof(pid_t)) return fail(@"process enumeration");
            NSMutableDictionary *current = [NSMutableDictionary dictionary];
            for (int i = 0; i < bytes / (int)sizeof(pid_t); i++) {
                if (pids[i] <= 0 || pids[i] == getpid()) continue;
                NSDictionary *entry = nil;
                struct FixtureProcess classified = {0};
                enum FixtureDecision decision = observeProcess(pids[i], observed, root, cache, &entry, &classified, &pathRetryBudget);
                if (decision == FixtureDecisionUnknown) return fail(@"process ownership or identity unknown");
                if (decision == FixtureDecisionChanged) return 3;
                if (classified.pid > 0) finalInventory[@(classified.pid)] = [NSValue valueWithBytes:&classified objCType:@encode(struct FixtureProcess)];
                if (decision == FixtureDecisionOwned) {
                    NSString *key = identityKey(entryValue(entry));
                    if (pass == 2 && !previousPass[key]) {
                        fprintf(stderr, "Fixture owned identity appeared during final inventory\n"); return 3;
                    }
                    current[key] = entry;
                    observed[key] = entry;
                    if (observed.count > 32) return fail(@"owned identity budget");
                }
            }
            previousPass = current;
            lastPass = current;
        }
        NSMutableArray *processes = [NSMutableArray array];
        for (NSDictionary *entry in observed.allValues) {
            struct FixtureProcess expected = entryValue(entry), first = {0}, second = {0};
            int firstError = 0, secondError = 0;
            enum FixtureLookup firstLookup = lookupProcess((pid_t)expected.pid, &first, &firstError);
            enum FixtureLookup secondLookup = lookupProcess((pid_t)expected.pid, &second, &secondError);
            struct FixtureProcess classified = {0};
            NSValue *finalValue = finalInventory[@(expected.pid)];
            if (finalValue) [finalValue getValue:&classified size:sizeof(classified)];
            enum FixtureDecision decision = FixtureRecheck(expected, first, second, firstLookup, secondLookup,
                geteuid(), finalValue ? &classified : NULL);
            if (decision == FixtureDecisionUnknown || decision == FixtureDecisionChanged) {
                processDiagnostic("final-owned", decision, first, second, firstLookup, secondLookup,
                    FixtureScopeOwned, FixtureScopeOwned, YES, firstError, secondError, 0, 0, FixturePathNotRead, FixturePathNotRead);
                if (decision == FixtureDecisionChanged) return 3;
                return fail(@"tracked process inventory changed");
            }
            if (decision == FixtureDecisionOwned) {
                NSDictionary *last = lastPass[identityKey(expected)];
                if (!last) return fail(@"owned identity absent from final classification");
                [processes addObject:last];
            }
        }
        NSArray<NSRunningApplication *> *applications = [NSRunningApplication runningApplicationsWithBundleIdentifier:identifier];
        NSUInteger liveApps = 0;
        for (NSRunningApplication *application in applications) {
            if (application.terminated) continue;
            NSString *expectedApp = [root stringByAppendingPathComponent:[caseName stringByAppendingPathComponent:@"Installed/SparkleFixture.app"]];
            // Read AppKit metadata once. These properties may be unavailable;
            // their absence is distinct from a present contradictory value,
            // but neither condition proves that a fixture application is gone.
            NSURL *bundleURL = application.bundleURL;
            NSString *bundleIdentifier = application.bundleIdentifier;
            errno = 0;
            NSString *physicalApp = bundleURL ? physicalPath(bundleURL.path) : nil;
            int bundlePathError = physicalApp || !bundleURL ? 0 : errno;
            errno = 0;
            NSString *physicalExpectedApp = physicalPath(expectedApp);
            int expectedPathError = physicalExpectedApp ? 0 : errno;
            struct stat appInfo = {0}; errno = 0;
            int appStatResult = lstat(expectedApp.fileSystemRepresentation, &appInfo);
            int appStatError = appStatResult == 0 ? 0 : errno;
            BOOL appPathMatches = physicalApp && [physicalApp isEqualToString:expectedApp];
            BOOL expectedPathMatches = physicalExpectedApp && [physicalExpectedApp isEqualToString:expectedApp];
            BOOL appIsDirectory = appStatResult == 0 && S_ISDIR(appInfo.st_mode);
            BOOL appOwnerMatches = appStatResult == 0 && appInfo.st_uid == geteuid();
            BOOL bundleIdentifierMatches = [bundleIdentifier isEqualToString:identifier];
            if (!physicalApp || !appPathMatches || !expectedPathMatches || appStatResult ||
                !appIsDirectory || !appOwnerMatches || !bundleIdentifierMatches) {
                // Diagnostics only: do not use cached launch/termination flags
                // or a later BSD lookup to turn this refusal into absence.
                pid_t appPID = application.processIdentifier;
                struct FixtureProcess first = {0}, second = {0}, classified = {0};
                int firstError = 0, secondError = 0;
                enum FixtureLookup firstLookup = FixtureLookupUnknown, secondLookup = FixtureLookupUnknown;
                if (appPID > 0) {
                    firstLookup = lookupProcess(appPID, &first, &firstError);
                    secondLookup = lookupProcess(appPID, &second, &secondError);
                }
                NSValue *finalValue = appPID > 0 ? finalInventory[@(appPID)] : nil;
                if (finalValue) [finalValue getValue:&classified size:sizeof(classified)];
                BOOL bothPresent = firstLookup == FixtureLookupPresent && secondLookup == FixtureLookupPresent;
                BOOL classifiedMatch = bothPresent && finalValue && FixtureSameIdentity(classified, first) && FixtureSameIdentity(classified, second);
                BOOL knownMatch = knownEntry(observed, first, second, firstLookup, secondLookup) != nil;
                fprintf(stderr, "Fixture app identity diagnostic: bundle_url=%d bundle_physical=%d bundle_path_match=%d bundle_path_errno=%d "
                    "expected_physical=%d expected_path_match=%d expected_path_errno=%d stat_ok=%d stat_errno=%d directory=%d owner_match=%d "
                    "bundle_id_present=%d bundle_id_match=%d cached_terminated=%d cached_finished_launching=%d pid_available=%d "
                    "lookup=%d,%d lookup_errno=%d,%d identity_equal=%d uid_equal=%d,%d zombie=%d,%d known_match_either=%d classified_match=%d\n",
                    bundleURL != nil, physicalApp != nil, appPathMatches, bundlePathError,
                    physicalExpectedApp != nil, expectedPathMatches, expectedPathError, appStatResult == 0, appStatError, appIsDirectory, appOwnerMatches,
                    bundleIdentifier != nil, bundleIdentifierMatches, application.terminated, application.finishedLaunching, appPID > 0,
                    firstLookup, secondLookup, firstError, secondError, bothPresent && FixtureSameIdentity(first, second),
                    FixtureExpectedUser(first, geteuid()), FixtureExpectedUser(second, geteuid()), first.zombie, second.zombie, knownMatch, classifiedMatch);
                return fail(@"app identity mismatch");
            }
            liveApps++;
        }
        NSMutableDictionary *services = [NSMutableDictionary dictionary];
        BOOL absent = YES;
        // Pinned Sparkle 2.10.0 names; success is conservatively still active.
        for (NSString *suffix in @[@"-spki", @"-spks", @"-spkp"]) {
            NSString *name = [identifier stringByAppendingString:suffix];
            if (name.length >= 128) return fail(@"service name bound");
            mach_port_t port = MACH_PORT_NULL;
            kern_return_t status = bootstrap_look_up(bootstrap_port, name.UTF8String, &port);
            if (status == KERN_SUCCESS) {
                if (port == MACH_PORT_NULL) return fail(@"invalid service right");
                if (mach_port_deallocate(mach_task_self(), port) != KERN_SUCCESS) return fail(@"service right disposal");
                services[suffix] = @"registered"; absent = NO;
            } else if (status == BOOTSTRAP_UNKNOWN_SERVICE) services[suffix] = @"absent";
            else return fail(@"bootstrap lookup uncertain");
        }
        if (lstat(root.fileSystemRepresentation, &after) || lstat(namedRoot.fileSystemRepresentation, &named) ||
            fstat(rootFD, &pinned) || !sameRoot(before, after) || !sameRoot(before, named) || !sameRoot(before, pinned)) return fail(@"root changed");
        close(rootFD);
        NSDictionary *result = @{@"schema": @1, @"bundle_id": identifier, @"uid": @(geteuid()), @"app_count": @(liveApps),
            @"owned_processes": processes, @"services": services, @"idle": FixtureJSONBoolean(absent && liveApps == 0 && processes.count == 0)};
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:NULL];
        if (!json || fwrite(json.bytes, 1, json.length, stdout) != json.length || fputc('\n', stdout) == EOF) return fail(@"output");
        return 0;
    }
}
