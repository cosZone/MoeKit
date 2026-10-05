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

static BOOL sameProcess(struct proc_bsdinfo a, struct proc_bsdinfo b) {
    return a.pbi_pid == b.pbi_pid && a.pbi_uid == b.pbi_uid && a.pbi_ruid == b.pbi_ruid &&
        a.pbi_start_tvsec == b.pbi_start_tvsec && a.pbi_start_tvusec == b.pbi_start_tvusec;
}
static int fail(NSString *reason) {
    fprintf(stderr, "Fixture lifetime probe unknown: %s\n", reason.UTF8String);
    return 2;
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 5 || geteuid() == 0 || ![NSProcessInfo.processInfo.environment[@"GITHUB_ACTIONS"] isEqualToString:@"true"] ||
            ![NSProcessInfo.processInfo.environment[@"RUNNER_ENVIRONMENT"] isEqualToString:@"github-hosted"]) return fail(@"CI gate");
        NSString *root = [NSString stringWithUTF8String:argv[1]], *identifier = [NSString stringWithUTF8String:argv[2]];
        NSString *marker = [NSString stringWithUTF8String:argv[3]];
        NSRegularExpression *markerPattern = [NSRegularExpression regularExpressionWithPattern:@"^[a-f0-9]{32}$" options:0 error:NULL];
        NSRegularExpression *identifierPattern = [NSRegularExpression regularExpressionWithPattern:@"^org\\.moekit\\.CIFixture\\.r[a-f0-9]{32}\\.[a-z]+$" options:0 error:NULL];
        if ([markerPattern numberOfMatchesInString:marker options:0 range:NSMakeRange(0, marker.length)] != 1 ||
            [identifierPattern numberOfMatchesInString:identifier options:0 range:NSMakeRange(0, identifier.length)] != 1 ||
            ![identifier hasPrefix:[@"org.moekit.CIFixture.r" stringByAppendingFormat:@"%@.", marker]] ||
            ![root.lastPathComponent hasPrefix:@"moekit-sparkle-"] ||
            ![root isEqualToString:root.stringByResolvingSymlinksInPath]) return fail(@"fixture identity");
        struct stat before, after;
        if (lstat(root.fileSystemRepresentation, &before) || !S_ISDIR(before.st_mode) || before.st_uid != geteuid() ||
            (before.st_mode & 0777) != 0700) return fail(@"root identity");
        int rootFD = open(root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (rootFD < 0) return fail(@"root descriptor");
        int markerFD = openat(rootFD, "owner-marker", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        char markerBytes[33] = {0}; struct stat markerInfo;
        BOOL markerValid = markerFD >= 0 && !fstat(markerFD, &markerInfo) && S_ISREG(markerInfo.st_mode) &&
            markerInfo.st_nlink == 1 && markerInfo.st_uid == geteuid() && read(markerFD, markerBytes, sizeof(markerBytes)) == 32 &&
            [marker isEqualToString:[[NSString alloc] initWithBytes:markerBytes length:32 encoding:NSUTF8StringEncoding]];
        if (markerFD >= 0) close(markerFD);
        close(rootFD);
        if (!markerValid) return fail(@"owner marker");
        NSString *prefix = [root stringByAppendingString:@"/"];
        NSString *cache = [NSHomeDirectory() stringByAppendingPathComponent:[@"Library/Caches" stringByAppendingPathComponent:identifier]];
        NSString *cachePrefix = [cache stringByAppendingString:@"/"];
        NSData *trackedData = [[NSString stringWithUTF8String:argv[4]] dataUsingEncoding:NSUTF8StringEncoding];
        NSArray *tracked = [NSJSONSerialization JSONObjectWithData:trackedData options:0 error:NULL];
        if (![tracked isKindOfClass:NSArray.class] || tracked.count > 32) return fail(@"tracked identity input");
        for (NSDictionary *entry in tracked) {
            if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"pid"] isKindOfClass:NSNumber.class] ||
                ![entry[@"uid"] isKindOfClass:NSNumber.class] || [entry[@"uid"] unsignedIntValue] != geteuid() ||
                ![entry[@"start_seconds"] isKindOfClass:NSNumber.class] || ![entry[@"start_microseconds"] isKindOfClass:NSNumber.class] ||
                ![entry[@"role"] isKindOfClass:NSString.class]) return fail(@"tracked identity shape");
        }
        NSMutableArray *processes = [NSMutableArray array];
        pid_t pids[16384];
        NSMutableSet<NSNumber *> *lastInventory = [NSMutableSet set];
        for (int pass = 0; pass < 2; pass++) {
        [lastInventory removeAllObjects];
        int bytes = proc_listpids(PROC_UID_ONLY, getuid(), pids, sizeof(pids));
        if (bytes <= 0 || bytes >= (int)sizeof(pids) || bytes % (int)sizeof(pid_t)) return fail(@"process enumeration");
        for (int i = 0; i < bytes / (int)sizeof(pid_t); i++) {
            if (pids[i] <= 0 || pids[i] == getpid()) continue;
            [lastInventory addObject:@(pids[i])];
            struct proc_bsdinfo first = {0}, second = {0};
            errno = 0;
            if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 1, &first, sizeof(first)) != (int)sizeof(first)) {
                if (errno == ESRCH) continue;
                return fail(@"process identity unavailable");
            }
            if (first.pbi_ruid != getuid() || first.pbi_uid != geteuid()) return fail(@"process user changed");
            char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
            int pathLength = proc_pidpath(pids[i], path, sizeof(path));
            errno = 0;
            if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 1, &second, sizeof(second)) != (int)sizeof(second)) {
                if (errno == ESRCH) continue;
                return fail(@"process recheck unavailable");
            }
            if (!sameProcess(first, second)) return fail(@"process identity changed");
            // A stable zombie cannot execute or launch more fixture helpers.
            // The Python owner separately reaps its original direct child.
            if (second.pbi_status == SZOMB) continue;
            if (pathLength <= 0 || pathLength >= (int)sizeof(path)) return fail(@"process executable unavailable");
            NSString *executable = [NSString stringWithUTF8String:path];
            if (!executable) return fail(@"process executable encoding");
            NSDictionary *known = nil;
            for (NSDictionary *entry in tracked) {
                if ([entry[@"pid"] intValue] == pids[i] && [entry[@"uid"] unsignedIntValue] == first.pbi_uid &&
                    [entry[@"start_seconds"] unsignedLongLongValue] == first.pbi_start_tvsec &&
                    [entry[@"start_microseconds"] unsignedLongLongValue] == first.pbi_start_tvusec) { known = entry; break; }
            }
            if ([executable hasPrefix:prefix] || [executable hasPrefix:cachePrefix] || known) {
                NSString *role = known ? known[@"role"] :
                    [executable hasSuffix:@"/Sparkle.framework/Versions/B/Autoupdate"] ? @"installer" :
                    [executable hasSuffix:@"/Updater.app/Contents/MacOS/Updater"] ? @"progress-agent" : @"fixture-process";
                [processes addObject:@{@"pid": @(pids[i]), @"uid": @(first.pbi_uid),
                    @"start_seconds": @(first.pbi_start_tvsec), @"start_microseconds": @(first.pbi_start_tvusec),
                    @"role": role, @"scope": known ? @"tracked-identity" : [executable hasPrefix:prefix] ? @"owned-root" : @"exact-fixture-cache"}];
            }
        }
        }
        // Refuse an inventory gap, including a tracked process changing user.
        int finalBytes = proc_listpids(PROC_UID_ONLY, getuid(), pids, sizeof(pids));
        if (finalBytes <= 0 || finalBytes >= (int)sizeof(pids) || finalBytes % (int)sizeof(pid_t)) return fail(@"process inventory recheck");
        for (int i = 0; i < finalBytes / (int)sizeof(pid_t); i++)
            if (pids[i] > 0 && pids[i] != getpid() && ![lastInventory containsObject:@(pids[i])]) { fprintf(stderr, "Fixture lifetime snapshot changed during enumeration\n"); return 3; }
        for (NSDictionary *entry in tracked) {
            struct proc_bsdinfo current = {0}; errno = 0;
            if (proc_pidinfo([entry[@"pid"] intValue], PROC_PIDTBSDINFO, 1, &current, sizeof(current)) != (int)sizeof(current)) {
                if (errno == ESRCH) continue;
                return fail(@"tracked process recheck unavailable");
            }
            if (current.pbi_start_tvsec == [entry[@"start_seconds"] unsignedLongLongValue] &&
                current.pbi_start_tvusec == [entry[@"start_microseconds"] unsignedLongLongValue] && current.pbi_status != SZOMB &&
                (current.pbi_uid != geteuid() || current.pbi_ruid != getuid() || ![lastInventory containsObject:entry[@"pid"]]))
                return fail(@"tracked process inventory changed");
        }
        NSArray<NSRunningApplication *> *applications = [NSRunningApplication runningApplicationsWithBundleIdentifier:identifier];
        NSUInteger liveApps = 0;
        for (NSRunningApplication *application in applications) {
            if (application.terminated) continue;
            if (!application.bundleURL || ![application.bundleURL.path hasPrefix:prefix] ||
                ![application.bundleIdentifier isEqualToString:identifier]) return fail(@"app identity mismatch");
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
        if (lstat(root.fileSystemRepresentation, &after) || before.st_dev != after.st_dev || before.st_ino != after.st_ino ||
            after.st_uid != geteuid() || !S_ISDIR(after.st_mode) || (after.st_mode & 0777) != 0700) return fail(@"root changed");
        NSDictionary *result = @{@"schema": @1, @"bundle_id": identifier, @"uid": @(geteuid()), @"app_count": @(liveApps),
            @"owned_processes": processes, @"services": services, @"idle": @(absent && liveApps == 0 && processes.count == 0)};
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:NULL];
        if (!json || fwrite(json.bytes, 1, json.length, stdout) != json.length || fputc('\n', stdout) == EOF) return fail(@"output");
        return 0;
    }
}
