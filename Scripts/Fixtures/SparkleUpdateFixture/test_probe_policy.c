// Injected portable policy tests, not evidence of native Sparkle execution.
// cc -std=c11 -Wall -Wextra -Werror test_probe_policy.c -o /tmp/probe-policy-test
#include "probe_policy.h"

#include <assert.h>
#include <stdio.h>

#ifdef NDEBUG
#error "These policy tests require assertions."
#endif

static size_t casesRun;

static void check(bool condition, const char *name) {
    if (!condition) fprintf(stderr, "Failed policy case: %s\n", name);
    assert(condition);
    casesRun++;
}

static void checkDecision(enum FixtureDecision actual, enum FixtureDecision expected, const char *name) {
    if (actual != expected)
        fprintf(stderr, "Policy decision for %s: expected %d, got %d\n", name, (int)expected, (int)actual);
    check(actual == expected, name);
}

static void testNormalUser(void) {
    const struct {
        const char *name;
        uint32_t realUID, effectiveUID;
        bool expected;
    } cases[] = {
        {"ordinary user", 501, 501, true},
        {"another ordinary user", 502, 502, true},
        {"root", 0, 0, false},
        {"root real UID", 0, 501, false},
        {"root effective UID", 501, 0, false},
        {"different non-root UIDs", 501, 502, false},
        {"full-width user ID", UINT32_MAX, UINT32_MAX, true}
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++)
        check(FixtureNormalUser(cases[i].realUID, cases[i].effectiveUID) == cases[i].expected, cases[i].name);
}

static void testIdentity(void) {
    const struct FixtureProcess original = {77, 501, 501, 100, 12, false};
    struct FixtureProcess changed = original;
    check(FixtureSameIdentity(original, original), "equal PID/start");
    changed.pid++;
    check(!FixtureSameIdentity(original, changed), "different PID");
    changed = original; changed.seconds++;
    check(!FixtureSameIdentity(original, changed), "PID reused at another second");
    changed = original; changed.microseconds++;
    check(!FixtureSameIdentity(original, changed), "PID reused within one second");
    changed = original; changed.euid++;
    check(FixtureSameIdentity(original, changed), "EUID is not PID/start identity");
    changed = original; changed.ruid++;
    check(FixtureSameIdentity(original, changed), "RUID is not PID/start identity");
    changed = original; changed.zombie = true;
    check(FixtureSameIdentity(original, changed), "zombie flag is not PID/start identity");
    changed = original; changed.seconds += UINT64_C(1) << 32;
    check(!FixtureSameIdentity(original, changed), "start seconds never truncate to 32 bits");
    changed = original; changed.microseconds += UINT64_C(1) << 32;
    check(!FixtureSameIdentity(original, changed), "start microseconds never truncate to 32 bits");
}

static void testPaths(void) {
    const char *root = "/private/var/moekit-sparkle-owned";
    const char *cache = "/Users/fixture/Library/Caches/org.moekit.CIFixture.rabc.valid";
    const struct {
        const char *name, *path;
        enum FixtureScope expected;
    } cases[] = {
        {"exact root", root, FixtureScopeOwned},
        {"root child", "/private/var/moekit-sparkle-owned/probe", FixtureScopeOwned},
        {"nested root child", "/private/var/moekit-sparkle-owned/valid/Installed/app", FixtureScopeOwned},
        {"exact cache", cache, FixtureScopeOwned},
        {"cache child", "/Users/fixture/Library/Caches/org.moekit.CIFixture.rabc.valid/Updater", FixtureScopeOwned},
        {"root sibling prefix", "/private/var/moekit-sparkle-owned-neighbor/probe", FixtureScopeOutside},
        {"root appended character", "/private/var/moekit-sparkle-ownedevil", FixtureScopeOutside},
        {"cache sibling prefix", "/Users/fixture/Library/Caches/org.moekit.CIFixture.rabc.valid-other/helper", FixtureScopeOutside},
        {"cache appended character", "/Users/fixture/Library/Caches/org.moekit.CIFixture.rabc.validx", FixtureScopeOutside},
        {"parent of root", "/private/var", FixtureScopeOutside},
        {"parent of cache", "/Users/fixture/Library/Caches", FixtureScopeOutside},
        {"system executable", "/usr/libexec/unrelated", FixtureScopeOutside},
        {"filesystem root outside", "/", FixtureScopeOutside},
        {"alias is not silently physically resolved", "/var/moekit-sparkle-owned/probe", FixtureScopeOutside},
        {"null executable", NULL, FixtureScopeUnknown},
        {"empty executable", "", FixtureScopeUnknown},
        {"relative executable", "private/var/moekit-sparkle-owned/probe", FixtureScopeUnknown},
        {"double leading slash", "//private/var/moekit-sparkle-owned/probe", FixtureScopeUnknown},
        {"double interior slash", "/private/var//moekit-sparkle-owned/probe", FixtureScopeUnknown},
        {"trailing slash", "/private/var/moekit-sparkle-owned/", FixtureScopeUnknown},
        {"dot component", "/private/var/./moekit-sparkle-owned/probe", FixtureScopeUnknown},
        {"dot terminal", "/private/var/moekit-sparkle-owned/.", FixtureScopeUnknown},
        {"dotdot component", "/private/var/moekit-sparkle-owned/../unrelated", FixtureScopeUnknown},
        {"dotdot terminal", "/private/var/moekit-sparkle-owned/..", FixtureScopeUnknown},
        {"only root dot", "/.", FixtureScopeUnknown},
        {"only root dotdot", "/..", FixtureScopeUnknown},
        {"only empty components", "//", FixtureScopeUnknown},
        {"hidden filename", "/private/var/moekit-sparkle-owned/.helper", FixtureScopeOwned},
        {"dot-prefixed filename", "/private/var/moekit-sparkle-owned/..helper", FixtureScopeOwned},
        {"three-dot filename", "/private/var/moekit-sparkle-owned/...", FixtureScopeOwned},
        {"literal percent filename", "/private/var/moekit-sparkle-owned/%2e%2e/helper", FixtureScopeOwned},
        {"literal backslash filename", "/private/var/moekit-sparkle-owned/a\\b", FixtureScopeOwned}
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++)
        check(FixturePathScope(cases[i].path, root, cache) == cases[i].expected, cases[i].name);

    const char *badRoots[] = {NULL, "", "relative", "/root/", "/root//child", "/root/.", "/root/../child"};
    for (size_t i = 0; i < sizeof(badRoots) / sizeof(badRoots[0]); i++) {
        check(FixturePathScope(cache, badRoots[i], cache) == FixtureScopeUnknown, "invalid root cannot establish scope");
        check(FixturePathScope(root, root, badRoots[i]) == FixtureScopeUnknown, "invalid cache cannot establish scope");
    }
    check(FixturePathScope("/child", "/", cache) == FixtureScopeOwned, "filesystem root owns descendants");
    check(FixturePathScope("/", "/", cache) == FixtureScopeOwned, "filesystem root exact match");
    check(FixturePathScope("/child", root, "/") == FixtureScopeOwned, "filesystem cache root owns descendants");
    check(FixturePathScope("/r", "/root", "/cache") == FixtureScopeOutside, "short path boundary safe");
}

static void testClassify(void) {
    const struct FixtureProcess live = {77, 501, 501, 100, 12, false};
    struct FixtureProcess realRoot = live, effectiveOther = live, bothOther = live;
    struct FixtureProcess zombie = live, reused = live, reusedMicroseconds = live, otherPID = live;
    realRoot.ruid = 0;
    effectiveOther.euid = 502;
    bothOther.euid = 502; bothOther.ruid = 502;
    zombie.zombie = true;
    reused.seconds++;
    reusedMicroseconds.microseconds++;
    otherPID.pid++;
    struct FixtureProcess wrongRealZombie = zombie; wrongRealZombie.ruid = 0;
    struct FixtureProcess wrongEffectiveZombie = zombie; wrongEffectiveZombie.euid = 502;

    const struct {
        const char *name;
        struct FixtureProcess first, second;
        enum FixtureLookup firstLookup, secondLookup;
        enum FixtureScope firstScope, secondScope;
        uint32_t expectedUID;
        const struct FixtureProcess *known;
        enum FixtureDecision expected;
    } cases[] = {
#define CLASSIFY(NAME, FIRST, SECOND, FIRST_SCOPE, SECOND_SCOPE, KNOWN, EXPECTED) \
        {NAME, FIRST, SECOND, FixtureLookupPresent, FixtureLookupPresent, FIRST_SCOPE, SECOND_SCOPE, 501, KNOWN, EXPECTED}
        CLASSIFY("stable unrelated user", live, live, FixtureScopeOutside, FixtureScopeOutside, NULL, FixtureDecisionOutside),
        CLASSIFY("stable unrelated mixed RUID", realRoot, realRoot, FixtureScopeOutside, FixtureScopeOutside, NULL, FixtureDecisionOutside),
        CLASSIFY("stable unrelated other EUID", effectiveOther, effectiveOther, FixtureScopeOutside, FixtureScopeOutside, NULL, FixtureDecisionOutside),
        CLASSIFY("stable unrelated foreign user", bothOther, bothOther, FixtureScopeOutside, FixtureScopeOutside, NULL, FixtureDecisionOutside),
        CLASSIFY("unrelated RUID transition", live, realRoot, FixtureScopeOutside, FixtureScopeOutside, NULL, FixtureDecisionOutside),
        CLASSIFY("unrelated EUID transition", live, effectiveOther, FixtureScopeOutside, FixtureScopeOutside, NULL, FixtureDecisionOutside),
        CLASSIFY("stable owned identity", live, live, FixtureScopeOwned, FixtureScopeOwned, NULL, FixtureDecisionOwned),
        CLASSIFY("outside into owned", live, live, FixtureScopeOutside, FixtureScopeOwned, NULL, FixtureDecisionOwned),
        CLASSIFY("untracked owned out of scope", live, live, FixtureScopeOwned, FixtureScopeOutside, NULL, FixtureDecisionChanged),
        CLASSIFY("owned mixed RUID", realRoot, realRoot, FixtureScopeOwned, FixtureScopeOwned, NULL, FixtureDecisionUnknown),
        CLASSIFY("owned wrong EUID", effectiveOther, effectiveOther, FixtureScopeOwned, FixtureScopeOwned, NULL, FixtureDecisionUnknown),
        CLASSIFY("owned foreign user", bothOther, bothOther, FixtureScopeOwned, FixtureScopeOwned, NULL, FixtureDecisionUnknown),
        CLASSIFY("owned initial RUID mismatch", realRoot, live, FixtureScopeOwned, FixtureScopeOwned, NULL, FixtureDecisionUnknown),
        CLASSIFY("owned final RUID mismatch", live, realRoot, FixtureScopeOwned, FixtureScopeOwned, NULL, FixtureDecisionUnknown),
        CLASSIFY("owned initial EUID mismatch", effectiveOther, live, FixtureScopeOwned, FixtureScopeOwned, NULL, FixtureDecisionUnknown),
        CLASSIFY("owned final EUID mismatch", live, effectiveOther, FixtureScopeOwned, FixtureScopeOwned, NULL, FixtureDecisionUnknown),
        CLASSIFY("first owned path enforces UID", realRoot, realRoot, FixtureScopeOwned, FixtureScopeOutside, NULL, FixtureDecisionUnknown),
        CLASSIFY("second owned path enforces UID", realRoot, realRoot, FixtureScopeOutside, FixtureScopeOwned, NULL, FixtureDecisionUnknown),
        CLASSIFY("both executable paths unavailable", live, live, FixtureScopeUnknown, FixtureScopeUnknown, NULL, FixtureDecisionUnknown),
        CLASSIFY("initial executable unavailable", live, live, FixtureScopeUnknown, FixtureScopeOutside, NULL, FixtureDecisionUnknown),
        CLASSIFY("final executable unavailable", live, live, FixtureScopeOutside, FixtureScopeUnknown, NULL, FixtureDecisionUnknown),
        CLASSIFY("owned then unresolved executable", live, live, FixtureScopeOwned, FixtureScopeUnknown, NULL, FixtureDecisionUnknown),
        CLASSIFY("unresolved then owned executable", live, live, FixtureScopeUnknown, FixtureScopeOwned, NULL, FixtureDecisionUnknown),
        CLASSIFY("invalid initial scope", live, live, (enum FixtureScope)99, FixtureScopeOwned, NULL, FixtureDecisionUnknown),
        CLASSIFY("invalid final scope", live, live, FixtureScopeOutside, (enum FixtureScope)99, NULL, FixtureDecisionUnknown),
        CLASSIFY("known removed executable stays active", live, live, FixtureScopeUnknown, FixtureScopeUnknown, &live, FixtureDecisionOwned),
        CLASSIFY("known relocated executable stays active", live, live, FixtureScopeOutside, FixtureScopeOutside, &live, FixtureDecisionOwned),
        CLASSIFY("known moving executable stays active", live, live, FixtureScopeOwned, FixtureScopeOutside, &live, FixtureDecisionOwned),
        CLASSIFY("known first unresolved path", live, live, FixtureScopeUnknown, FixtureScopeOwned, &live, FixtureDecisionOwned),
        CLASSIFY("known final unresolved path", live, live, FixtureScopeOwned, FixtureScopeUnknown, &live, FixtureDecisionOwned),
        CLASSIFY("known initial RUID mismatch", realRoot, live, FixtureScopeOutside, FixtureScopeOutside, &live, FixtureDecisionUnknown),
        CLASSIFY("known final RUID mismatch", live, realRoot, FixtureScopeOutside, FixtureScopeOutside, &live, FixtureDecisionUnknown),
        CLASSIFY("known stable mixed RUID", realRoot, realRoot, FixtureScopeUnknown, FixtureScopeUnknown, &live, FixtureDecisionUnknown),
        CLASSIFY("known initial EUID mismatch", effectiveOther, live, FixtureScopeOutside, FixtureScopeOutside, &live, FixtureDecisionUnknown),
        CLASSIFY("known final EUID mismatch", live, effectiveOther, FixtureScopeOutside, FixtureScopeOutside, &live, FixtureDecisionUnknown),
        CLASSIFY("known stable wrong EUID", effectiveOther, effectiveOther, FixtureScopeUnknown, FixtureScopeUnknown, &live, FixtureDecisionUnknown),
        CLASSIFY("stale known PID does not own replacement", reused, reused, FixtureScopeOutside, FixtureScopeOutside, &live, FixtureDecisionOutside),
        CLASSIFY("stale known PID cannot resolve replacement path", reused, reused, FixtureScopeUnknown, FixtureScopeUnknown, &live, FixtureDecisionUnknown),
        CLASSIFY("stale known PID replacement owned independently", reused, reused, FixtureScopeOwned, FixtureScopeOwned, &live, FixtureDecisionOwned),
        CLASSIFY("stale known other PID cannot own unrelated process", live, live, FixtureScopeOutside, FixtureScopeOutside, &otherPID, FixtureDecisionOutside),
        CLASSIFY("live PID reused between reads", live, reused, FixtureScopeOutside, FixtureScopeOutside, NULL, FixtureDecisionChanged),
        CLASSIFY("PID reused within second between reads", live, reusedMicroseconds, FixtureScopeOwned, FixtureScopeOwned, NULL, FixtureDecisionChanged),
        CLASSIFY("PID changes between reads", live, otherPID, FixtureScopeOwned, FixtureScopeOwned, NULL, FixtureDecisionChanged),
        CLASSIFY("known matches only initial identity", live, reused, FixtureScopeUnknown, FixtureScopeUnknown, &live, FixtureDecisionChanged),
        CLASSIFY("known matches only final identity", reused, live, FixtureScopeUnknown, FixtureScopeUnknown, &live, FixtureDecisionChanged),
        CLASSIFY("owned stable zombie", zombie, zombie, FixtureScopeOwned, FixtureScopeOwned, NULL, FixtureDecisionGone),
        CLASSIFY("unresolved stable zombie", zombie, zombie, FixtureScopeUnknown, FixtureScopeUnknown, NULL, FixtureDecisionGone),
        CLASSIFY("known zombie gone despite removed executable", zombie, zombie, FixtureScopeUnknown, FixtureScopeUnknown, &live, FixtureDecisionGone),
        CLASSIFY("live becomes zombie at final read", live, zombie, FixtureScopeOwned, FixtureScopeOwned, NULL, FixtureDecisionGone),
        CLASSIFY("initial zombie does not hide live owned", zombie, live, FixtureScopeOwned, FixtureScopeOwned, NULL, FixtureDecisionOwned),
        CLASSIFY("initial zombie does not hide live known", zombie, live, FixtureScopeUnknown, FixtureScopeUnknown, &live, FixtureDecisionOwned),
        CLASSIFY("initial zombie does not resolve live unknown", zombie, live, FixtureScopeUnknown, FixtureScopeUnknown, NULL, FixtureDecisionUnknown),
        CLASSIFY("PID reuse after initial zombie", zombie, reused, FixtureScopeUnknown, FixtureScopeUnknown, &live, FixtureDecisionChanged),
        CLASSIFY("changed identity before final zombie", reused, zombie, FixtureScopeUnknown, FixtureScopeUnknown, &live, FixtureDecisionChanged),
        CLASSIFY("owned zombie RUID mismatch refuses", wrongRealZombie, wrongRealZombie, FixtureScopeOwned, FixtureScopeOwned, NULL, FixtureDecisionUnknown),
        CLASSIFY("known zombie RUID mismatch refuses", wrongRealZombie, wrongRealZombie, FixtureScopeUnknown, FixtureScopeUnknown, &live, FixtureDecisionUnknown),
        CLASSIFY("owned zombie EUID mismatch refuses", wrongEffectiveZombie, wrongEffectiveZombie, FixtureScopeOwned, FixtureScopeOwned, NULL, FixtureDecisionUnknown),
        CLASSIFY("known zombie EUID mismatch refuses", wrongEffectiveZombie, wrongEffectiveZombie, FixtureScopeUnknown, FixtureScopeUnknown, &live, FixtureDecisionUnknown),
        CLASSIFY("unknown-scope foreign zombie gone", wrongRealZombie, wrongRealZombie, FixtureScopeUnknown, FixtureScopeUnknown, NULL, FixtureDecisionGone),
#undef CLASSIFY
#define LOOKUP(NAME, FIRST_LOOKUP, SECOND_LOOKUP, EXPECTED) \
        {NAME, live, live, FIRST_LOOKUP, SECOND_LOOKUP, FixtureScopeOwned, FixtureScopeOwned, 501, &live, EXPECTED}
        LOOKUP("final ESRCH establishes gone", FixtureLookupPresent, FixtureLookupGone, FixtureDecisionGone),
        LOOKUP("both ESRCH establishes gone", FixtureLookupGone, FixtureLookupGone, FixtureDecisionGone),
        LOOKUP("initial ESRCH then live never establishes gone", FixtureLookupGone, FixtureLookupPresent, FixtureDecisionChanged),
        LOOKUP("initial inaccessible identity", FixtureLookupUnknown, FixtureLookupPresent, FixtureDecisionUnknown),
        LOOKUP("final inaccessible identity", FixtureLookupPresent, FixtureLookupUnknown, FixtureDecisionUnknown),
        LOOKUP("both inaccessible identity", FixtureLookupUnknown, FixtureLookupUnknown, FixtureDecisionUnknown),
        LOOKUP("initial uncertainty not erased by final ESRCH", FixtureLookupUnknown, FixtureLookupGone, FixtureDecisionUnknown),
        LOOKUP("initial ESRCH not enough with final uncertainty", FixtureLookupGone, FixtureLookupUnknown, FixtureDecisionUnknown),
        LOOKUP("invalid initial lookup", (enum FixtureLookup)99, FixtureLookupPresent, FixtureDecisionUnknown),
        LOOKUP("invalid final lookup", FixtureLookupPresent, (enum FixtureLookup)99, FixtureDecisionUnknown),
#undef LOOKUP
        {"zero expected owned UID refuses", live, live, FixtureLookupPresent, FixtureLookupPresent,
            FixtureScopeOwned, FixtureScopeOwned, 0, NULL, FixtureDecisionUnknown},
        {"wrong expected known UID refuses", live, live, FixtureLookupPresent, FixtureLookupPresent,
            FixtureScopeOutside, FixtureScopeOutside, 502, &live, FixtureDecisionUnknown}
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++)
        checkDecision(FixtureClassify(cases[i].first, cases[i].second,
            cases[i].firstLookup, cases[i].secondLookup, cases[i].firstScope, cases[i].secondScope,
            cases[i].expectedUID, cases[i].known), cases[i].expected, cases[i].name);
}

static void testRecheck(void) {
    const struct FixtureProcess live = {77, 501, 501, 100, 12, false};
    struct FixtureProcess realRoot = live, effectiveOther = live, zombie = live;
    struct FixtureProcess reused = live, reusedMicroseconds = live, otherPID = live;
    realRoot.ruid = 0;
    effectiveOther.euid = 502;
    zombie.zombie = true;
    reused.seconds++;
    reusedMicroseconds.microseconds++;
    otherPID.pid++;
    struct FixtureProcess wrongRealZombie = zombie; wrongRealZombie.ruid = 0;
    struct FixtureProcess wrongEffectiveZombie = zombie; wrongEffectiveZombie.euid = 502;
    struct FixtureProcess foreignReplacement = reused; foreignReplacement.ruid = 0;
    const struct {
        const char *name;
        struct FixtureProcess first, second;
        enum FixtureLookup firstLookup, secondLookup;
        uint32_t expectedUID;
        const struct FixtureProcess *finalClassified;
        enum FixtureDecision expected;
    } cases[] = {
#define RECHECK(NAME, FIRST, SECOND, CLASSIFIED, EXPECTED) \
        {NAME, FIRST, SECOND, FixtureLookupPresent, FixtureLookupPresent, 501, CLASSIFIED, EXPECTED}
        RECHECK("known remains in final classified inventory", live, live, &live, FixtureDecisionOwned),
        RECHECK("known final classified inventory omission", live, live, NULL, FixtureDecisionUnknown),
        RECHECK("known initial RUID transition", realRoot, live, &live, FixtureDecisionUnknown),
        RECHECK("known final RUID transition", live, realRoot, &live, FixtureDecisionUnknown),
        RECHECK("known stable mixed RUID recheck", realRoot, realRoot, &live, FixtureDecisionUnknown),
        RECHECK("known initial EUID transition", effectiveOther, live, &live, FixtureDecisionUnknown),
        RECHECK("known final EUID transition", live, effectiveOther, &live, FixtureDecisionUnknown),
        RECHECK("known stable wrong EUID recheck", effectiveOther, effectiveOther, &live, FixtureDecisionUnknown),
        RECHECK("classified stable reused PID means old role gone", reused, reused, &reused, FixtureDecisionGone),
        RECHECK("classified stable reused microsecond means old role gone", reusedMicroseconds, reusedMicroseconds, &reusedMicroseconds, FixtureDecisionGone),
        RECHECK("unclassified stable replacement is changed", reused, reused, NULL, FixtureDecisionChanged),
        RECHECK("unclassified foreign replacement is changed", foreignReplacement, foreignReplacement, NULL, FixtureDecisionChanged),
        RECHECK("classified foreign replacement means old identity gone", foreignReplacement, foreignReplacement, &foreignReplacement, FixtureDecisionGone),
        RECHECK("old classification never proves replacement classified", reused, reused, &live, FixtureDecisionChanged),
        RECHECK("old classification cannot miss subsecond replacement", reusedMicroseconds, reusedMicroseconds, &live, FixtureDecisionChanged),
        RECHECK("another PID classification cannot cover replacement", reused, reused, &otherPID, FixtureDecisionChanged),
        RECHECK("known identity requires matching classified start", live, live, &reused, FixtureDecisionUnknown),
        RECHECK("known identity requires matching classified PID", live, live, &otherPID, FixtureDecisionUnknown),
        RECHECK("PID changes within recheck", live, otherPID, &live, FixtureDecisionChanged),
        RECHECK("PID reused within recheck", live, reused, &live, FixtureDecisionChanged),
        RECHECK("reused identity then known identity is inconclusive", reused, live, &live, FixtureDecisionChanged),
        RECHECK("wrong requested PID cannot prove old identity gone", otherPID, otherPID, &otherPID, FixtureDecisionUnknown),
        RECHECK("final stable zombie", zombie, zombie, &live, FixtureDecisionGone),
        RECHECK("stable zombie absent from final inventory", zombie, zombie, NULL, FixtureDecisionGone),
        RECHECK("known live becomes zombie", live, zombie, &live, FixtureDecisionGone),
        RECHECK("known zombie first then live stays active", zombie, live, &live, FixtureDecisionOwned),
        RECHECK("known zombie first then live inventory omission", zombie, live, NULL, FixtureDecisionUnknown),
        RECHECK("PID reuse after zombie recheck", zombie, reused, &live, FixtureDecisionChanged),
        RECHECK("changed identity before zombie recheck", reused, zombie, &live, FixtureDecisionChanged),
        RECHECK("known zombie RUID mismatch recheck", wrongRealZombie, wrongRealZombie, &live, FixtureDecisionUnknown),
        RECHECK("known zombie EUID mismatch recheck", wrongEffectiveZombie, wrongEffectiveZombie, &live, FixtureDecisionUnknown),
#undef RECHECK
#define LOOKUP(NAME, FIRST_LOOKUP, SECOND_LOOKUP, EXPECTED) \
        {NAME, live, live, FIRST_LOOKUP, SECOND_LOOKUP, 501, &live, EXPECTED}
        LOOKUP("known final ESRCH gone", FixtureLookupPresent, FixtureLookupGone, FixtureDecisionGone),
        LOOKUP("known both ESRCH gone", FixtureLookupGone, FixtureLookupGone, FixtureDecisionGone),
        LOOKUP("known initial ESRCH then live changed", FixtureLookupGone, FixtureLookupPresent, FixtureDecisionChanged),
        LOOKUP("known first identity unavailable", FixtureLookupUnknown, FixtureLookupPresent, FixtureDecisionUnknown),
        LOOKUP("known final identity unavailable", FixtureLookupPresent, FixtureLookupUnknown, FixtureDecisionUnknown),
        LOOKUP("known both identity unavailable", FixtureLookupUnknown, FixtureLookupUnknown, FixtureDecisionUnknown),
        LOOKUP("known unknown then ESRCH", FixtureLookupUnknown, FixtureLookupGone, FixtureDecisionUnknown),
        LOOKUP("known ESRCH then unknown", FixtureLookupGone, FixtureLookupUnknown, FixtureDecisionUnknown),
        LOOKUP("known invalid initial lookup", (enum FixtureLookup)99, FixtureLookupPresent, FixtureDecisionUnknown),
        LOOKUP("known invalid final lookup", FixtureLookupPresent, (enum FixtureLookup)99, FixtureDecisionUnknown),
#undef LOOKUP
        {"known zero expected UID", live, live, FixtureLookupPresent, FixtureLookupPresent, 0, &live, FixtureDecisionUnknown},
        {"known wrong expected UID", live, live, FixtureLookupPresent, FixtureLookupPresent, 502, &live, FixtureDecisionUnknown}
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++)
        checkDecision(FixtureRecheck(live, cases[i].first, cases[i].second,
            cases[i].firstLookup, cases[i].secondLookup, cases[i].expectedUID, cases[i].finalClassified),
            cases[i].expected, cases[i].name);

    // A gone tracked role and a replacement process are separate obligations.
    // Never let a stale installer role exempt the current PID from discovery.
    checkDecision(FixtureRecheck(live, reused, reused, FixtureLookupPresent, FixtureLookupPresent,
        501, &reused), FixtureDecisionGone, "stale installer role removed only after replacement classified");
    checkDecision(FixtureClassify(reused, reused, FixtureLookupPresent, FixtureLookupPresent,
        FixtureScopeUnknown, FixtureScopeUnknown, 501, &live), FixtureDecisionUnknown,
        "replacement without executable evidence blocks stale-role absence");
    checkDecision(FixtureClassify(reused, reused, FixtureLookupPresent, FixtureLookupPresent,
        FixtureScopeOwned, FixtureScopeOwned, 501, &live), FixtureDecisionOwned,
        "replacement owned executable stays active after stale-role removal");
}

// Each observation injects the entire native BSD/path/path/BSD sequence into
// the same controller the probe uses. No real processes or credentials change.
struct RetryObservation {
    struct FixtureProcess first, second;
    enum FixtureLookup firstLookup, secondLookup;
    enum FixtureScope firstScope, secondScope;
    const struct FixtureProcess *known;
    bool firstKernelESRCH, secondKernelESRCH;
    uint32_t expectedUID;
};

static struct RetryObservation missingPaths(struct FixtureProcess process) {
    return (struct RetryObservation){process, process, FixtureLookupPresent, FixtureLookupPresent,
        FixtureScopeUnknown, FixtureScopeUnknown, NULL, true, true, 501};
}

static enum FixturePathRetryAction observeRetry(struct FixturePathRetryState *state,
                                                struct FixturePathRetryBudget *budget,
                                                struct RetryObservation sample, uint64_t now,
                                                enum FixtureDecision expectedDecision, const char *name) {
    enum FixtureDecision decision = FixtureClassify(sample.first, sample.second,
        sample.firstLookup, sample.secondLookup, sample.firstScope, sample.secondScope,
        sample.expectedUID, sample.known);
    checkDecision(decision, expectedDecision, name);
    return FixturePathRetryObserve(state, budget, sample.first, sample.second,
        sample.firstLookup, sample.secondLookup, sample.firstScope, sample.secondScope,
        sample.known, decision, sample.firstKernelESRCH, sample.secondKernelESRCH,
        sample.expectedUID, now);
}

static void checkRetry(enum FixturePathRetryAction actual, enum FixturePathRetryAction expected,
                       const char *name) {
    if (actual != expected)
        fprintf(stderr, "Retry action for %s: expected %d, got %d\n", name, (int)expected, (int)actual);
    check(actual == expected, name);
}

static void enterPathRetry(struct FixturePathRetryState *state, struct FixturePathRetryBudget *budget,
                           struct FixtureProcess process, uint64_t now) {
    unsigned before = budget->remaining;
    checkRetry(observeRetry(state, budget, missingPaths(process), now, FixtureDecisionUnknown,
                            "narrow kernel-path race remains unknown"),
               FixturePathRetryAgain, "narrow race reserves full re-observation");
    check(state->pending && FixtureSameIdentity(state->anchor, process), "unresolved identity anchor pinned");
    check(budget->remaining == before - 1, "one delayed retry reserved from invocation budget");
}

static void testPathRetryBudget(void) {
    check(FIXTURE_PATH_RETRY_WINDOW_NS == UINT64_C(1000000000), "one-second invocation retry window");
    check(FIXTURE_PATH_RETRY_DELAY_NS == UINT64_C(20000000), "twenty-millisecond retry delay");
    check(FIXTURE_PATH_RETRY_LIMIT == 6, "six delayed retries for entire invocation");
    struct FixturePathRetryBudget budget = FixtureMakePathRetryBudget(100);
    check(budget.start_ns == 100 && budget.last_ns == 100 &&
          budget.deadline_ns == 100 + FIXTURE_PATH_RETRY_WINDOW_NS &&
          budget.remaining == FIXTURE_PATH_RETRY_LIMIT, "budget starts without arithmetic drift");
    check(FixturePathRetryWithinBudget(&budget, 100), "initial instant inside budget");
    check(!FixturePathRetryWithinBudget(&budget, 99), "clock before invocation start refuses");
    check(FixturePathRetryWithinBudget(&budget, budget.deadline_ns - 1), "final nanosecond inside budget");
    check(!FixturePathRetryWithinBudget(&budget, budget.deadline_ns), "exact deadline expired");
    check(!FixturePathRetryWithinBudget(&budget, budget.deadline_ns + 1), "after deadline expired");
    budget.remaining = 0;
    check(FixturePathRetryWithinBudget(&budget, 100), "last reserved sample may use final token");
    budget.last_ns = 150;
    check(!FixturePathRetryWithinBudget(&budget, 149), "backwards time within global window refuses");
    check(FixturePathRetryWithinBudget(&budget, 150), "equal consecutive clock readings permitted");
    budget.last_ns = budget.start_ns - 1;
    check(!FixturePathRetryWithinBudget(&budget, 150), "invalid earlier clock floor refuses");
    budget.last_ns = budget.deadline_ns;
    check(!FixturePathRetryWithinBudget(&budget, budget.deadline_ns), "invalid expired clock floor refuses");
    check(!FixturePathRetryWithinBudget(NULL, 100), "missing budget refuses");
    budget = FixtureMakePathRetryBudget(UINT64_MAX - FIXTURE_PATH_RETRY_WINDOW_NS);
    check(budget.deadline_ns == UINT64_MAX && FixturePathRetryWithinBudget(&budget, budget.start_ns),
          "largest non-overflowing deadline remains valid");
    budget = FixtureMakePathRetryBudget(UINT64_MAX - FIXTURE_PATH_RETRY_WINDOW_NS + 1);
    check(budget.remaining == 0 && !FixturePathRetryWithinBudget(&budget, budget.start_ns),
          "deadline addition overflow refuses");
    budget = FixtureMakePathRetryBudget(UINT64_MAX);
    check(!FixturePathRetryWithinBudget(&budget, UINT64_MAX), "maximum clock cannot wrap deadline");
}

static void testPathRetryInitialEligibility(void) {
    const struct FixtureProcess live = {77, 501, 501, 100, 12, false};
    struct FixtureProcess other = live; other.pid++;
    struct FixturePathRetryState state = {0};
    struct FixturePathRetryBudget budget = FixtureMakePathRetryBudget(100);
    enterPathRetry(&state, &budget, live, 100);
    checkDecision(FixtureClassify(live, live, FixtureLookupPresent, FixtureLookupPresent,
        FixtureScopeUnknown, FixtureScopeUnknown, 501, NULL), FixtureDecisionUnknown,
        "pinned retry anchor grants no owned classification");

#define INITIAL_CASE(NAME, MUTATION, ACTION, DECISION) do { \
    struct RetryObservation sample = missingPaths(live); \
    MUTATION; \
    state = (struct FixturePathRetryState){0}; \
    budget = FixtureMakePathRetryBudget(100); \
    checkRetry(observeRetry(&state, &budget, sample, 100, DECISION, NAME), ACTION, NAME); \
    check(!state.pending && budget.remaining == FIXTURE_PATH_RETRY_LIMIT, \
          "ineligible first sample neither pins nor spends retry"); \
} while (0)
    INITIAL_CASE("known live identity needs no retry", sample.known = &live,
                 FixturePathRetryAccept, FixtureDecisionOwned);
    INITIAL_CASE("unrelated known pointer cannot request retry", sample.known = &other,
                 FixturePathRetryRefuse, FixtureDecisionUnknown);
    INITIAL_CASE("known UID mismatch cannot retry", sample.known = &live; sample.second.euid++,
                 FixturePathRetryRefuse, FixtureDecisionUnknown);
    INITIAL_CASE("realpath ESRCH is not kernel-path ESRCH", sample.firstKernelESRCH = false; sample.secondKernelESRCH = false,
                 FixturePathRetryRefuse, FixtureDecisionUnknown);
    INITIAL_CASE("first path permission error cannot retry", sample.firstKernelESRCH = false,
                 FixturePathRetryRefuse, FixtureDecisionUnknown);
    INITIAL_CASE("second path permission error cannot retry", sample.secondKernelESRCH = false,
                 FixturePathRetryRefuse, FixtureDecisionUnknown);
    INITIAL_CASE("first path classified cannot enter narrow retry", sample.firstScope = FixtureScopeOutside; sample.firstKernelESRCH = false,
                 FixturePathRetryRefuse, FixtureDecisionUnknown);
    INITIAL_CASE("second path classified cannot enter narrow retry", sample.secondScope = FixtureScopeOutside; sample.secondKernelESRCH = false,
                 FixturePathRetryRefuse, FixtureDecisionUnknown);
    INITIAL_CASE("unresolved owned-looking first path cannot retry", sample.firstScope = FixtureScopeOwned; sample.firstKernelESRCH = false,
                 FixturePathRetryRefuse, FixtureDecisionUnknown);
    INITIAL_CASE("invalid scope cannot retry", sample.firstScope = (enum FixtureScope)99,
                 FixturePathRetryRefuse, FixtureDecisionUnknown);
    INITIAL_CASE("metadata permission error cannot retry", sample.firstLookup = FixtureLookupUnknown,
                 FixturePathRetryRefuse, FixtureDecisionUnknown);
    INITIAL_CASE("metadata partial read cannot retry", sample.secondLookup = FixtureLookupUnknown,
                 FixturePathRetryRefuse, FixtureDecisionUnknown);
    INITIAL_CASE("invalid metadata category cannot retry", sample.secondLookup = (enum FixtureLookup)99,
                 FixturePathRetryRefuse, FixtureDecisionUnknown);
    INITIAL_CASE("initial real UID mismatch cannot retry", sample.first.ruid = 0,
                 FixturePathRetryRefuse, FixtureDecisionUnknown);
    INITIAL_CASE("final real UID mismatch cannot retry", sample.second.ruid++,
                 FixturePathRetryRefuse, FixtureDecisionUnknown);
    INITIAL_CASE("initial effective UID mismatch cannot retry", sample.first.euid++,
                 FixturePathRetryRefuse, FixtureDecisionUnknown);
    INITIAL_CASE("final effective UID mismatch cannot retry", sample.second.euid = 0,
                 FixturePathRetryRefuse, FixtureDecisionUnknown);
    INITIAL_CASE("zero PID cannot enter retry", sample.first.pid = 0; sample.second.pid = 0,
                 FixturePathRetryRefuse, FixtureDecisionUnknown);
    INITIAL_CASE("zero expected UID cannot retry", sample.expectedUID = 0,
                 FixturePathRetryRefuse, FixtureDecisionUnknown);
    INITIAL_CASE("wrong expected UID cannot retry", sample.expectedUID++,
                 FixturePathRetryRefuse, FixtureDecisionUnknown);
    INITIAL_CASE("initial zombie becoming live cannot retry", sample.first.zombie = true,
                 FixturePathRetryRefuse, FixtureDecisionUnknown);
    INITIAL_CASE("initial changed PID passes existing refusal through", sample.second.pid++,
                 FixturePathRetryAccept, FixtureDecisionChanged);
    INITIAL_CASE("initial changed start passes existing refusal through", sample.second.seconds++,
                 FixturePathRetryAccept, FixtureDecisionChanged);
    INITIAL_CASE("initial BSD disappearance needs no retry", sample.secondLookup = FixtureLookupGone,
                 FixturePathRetryAccept, FixtureDecisionGone);
    INITIAL_CASE("initial final zombie needs no retry", sample.second.zombie = true,
                 FixturePathRetryAccept, FixtureDecisionGone);
#undef INITIAL_CASE
    state = (struct FixturePathRetryState){0};
    budget = FixtureMakePathRetryBudget(100);
    checkRetry(FixturePathRetryObserve(&state, &budget, live, live,
        FixtureLookupPresent, FixtureLookupPresent, FixtureScopeUnknown, FixtureScopeUnknown,
        NULL, FixtureDecisionOwned, true, true, 501, 100), FixturePathRetryRefuse,
        "caller cannot fabricate owned decision from unresolved paths");
    checkRetry(FixturePathRetryObserve(NULL, &budget, live, live,
        FixtureLookupPresent, FixtureLookupPresent, FixtureScopeUnknown, FixtureScopeUnknown,
        NULL, FixtureDecisionUnknown, true, true, 501, 100), FixturePathRetryRefuse,
        "missing retry state refuses");
    checkRetry(FixturePathRetryObserve(&state, NULL, live, live,
        FixtureLookupPresent, FixtureLookupPresent, FixtureScopeUnknown, FixtureScopeUnknown,
        NULL, FixtureDecisionUnknown, true, true, 501, 100), FixturePathRetryRefuse,
        "missing invocation budget refuses");
}

static void testPathRetryResolution(void) {
    const struct FixtureProcess live = {77, 501, 501, 100, 12, false};
#define RESOLUTION_CASE(NAME, MUTATION, DECISION) do { \
    struct FixturePathRetryState state = {0}; \
    struct FixturePathRetryBudget budget = FixtureMakePathRetryBudget(100); \
    enterPathRetry(&state, &budget, live, 100); \
    struct RetryObservation sample = missingPaths(live); \
    MUTATION; \
    checkRetry(observeRetry(&state, &budget, sample, 100 + FIXTURE_PATH_RETRY_DELAY_NS, DECISION, NAME), \
               FixturePathRetryAccept, NAME); \
    check(!state.pending && budget.remaining == FIXTURE_PATH_RETRY_LIMIT - 1, \
          "affirmative resolution clears only pending state without spending another retry"); \
    check(budget.start_ns == 100 && budget.deadline_ns == 100 + FIXTURE_PATH_RETRY_WINDOW_NS, \
          "resolution never extends shared invocation deadline"); \
} while (0)
    RESOLUTION_CASE("pending race resolves by final BSD absence", sample.secondLookup = FixtureLookupGone,
                    FixtureDecisionGone);
    RESOLUTION_CASE("pending race resolves by two BSD absences with no path attempt",
                    sample.firstLookup = FixtureLookupGone; sample.secondLookup = FixtureLookupGone;
                    sample.firstKernelESRCH = false; sample.secondKernelESRCH = false,
                    FixtureDecisionGone);
    RESOLUTION_CASE("pending race resolves by live-to-zombie identity", sample.second.zombie = true,
                    FixtureDecisionGone);
    RESOLUTION_CASE("pending race resolves by stable zombie with no path attempt",
                    sample.first.zombie = true; sample.second.zombie = true;
                    sample.firstKernelESRCH = false; sample.secondKernelESRCH = false,
                    FixtureDecisionGone);
    RESOLUTION_CASE("pending race resolves zombie then BSD absence with no path attempt",
                    sample.first.zombie = true; sample.secondLookup = FixtureLookupGone;
                    sample.firstKernelESRCH = false; sample.secondKernelESRCH = false,
                    FixtureDecisionGone);
    RESOLUTION_CASE("pending race resolves with two fresh outside paths",
                    sample.firstScope = FixtureScopeOutside; sample.secondScope = FixtureScopeOutside;
                    sample.firstKernelESRCH = false; sample.secondKernelESRCH = false,
                    FixtureDecisionOutside);
    RESOLUTION_CASE("pending race resolves with two fresh owned paths",
                    sample.firstScope = FixtureScopeOwned; sample.secondScope = FixtureScopeOwned;
                    sample.firstKernelESRCH = false; sample.secondKernelESRCH = false,
                    FixtureDecisionOwned);
    RESOLUTION_CASE("pending recovery entering owned scope preserves classifier result",
                    sample.firstScope = FixtureScopeOutside; sample.secondScope = FixtureScopeOwned;
                    sample.firstKernelESRCH = false; sample.secondKernelESRCH = false,
                    FixtureDecisionOwned);
    RESOLUTION_CASE("BSD absence accepts one recovered path and one kernel ESRCH",
                    sample.firstScope = FixtureScopeOutside; sample.firstKernelESRCH = false;
                    sample.secondLookup = FixtureLookupGone,
                    FixtureDecisionGone);
#undef RESOLUTION_CASE
}

static void testPathRetryPendingRefusals(void) {
    const struct FixtureProcess live = {77, 501, 501, 100, 12, false};
#define PENDING_REFUSAL(NAME, MUTATION, DECISION) do { \
    struct FixturePathRetryState state = {0}; \
    struct FixturePathRetryBudget budget = FixtureMakePathRetryBudget(100); \
    enterPathRetry(&state, &budget, live, 100); \
    struct RetryObservation sample = missingPaths(live); \
    MUTATION; \
    checkRetry(observeRetry(&state, &budget, sample, 100 + FIXTURE_PATH_RETRY_DELAY_NS, DECISION, NAME), \
               FixturePathRetryRefuse, NAME); \
    check(state.pending && FixtureSameIdentity(state.anchor, live) && \
          budget.remaining == FIXTURE_PATH_RETRY_LIMIT - 1, \
          "refusal retains unresolved original anchor and spends no retry"); \
} while (0)
    PENDING_REFUSAL("stable replacement PID cannot erase anchor", sample.first.pid++; sample.second.pid++, FixtureDecisionUnknown);
    PENDING_REFUSAL("stable second-level PID reuse cannot erase anchor", sample.first.seconds++; sample.second.seconds++, FixtureDecisionUnknown);
    PENDING_REFUSAL("stable microsecond PID reuse cannot erase anchor", sample.first.microseconds++; sample.second.microseconds++, FixtureDecisionUnknown);
    PENDING_REFUSAL("replacement with real outside paths cannot erase anchor",
                    sample.first.seconds++; sample.second.seconds++;
                    sample.firstScope = FixtureScopeOutside; sample.secondScope = FixtureScopeOutside;
                    sample.firstKernelESRCH = false; sample.secondKernelESRCH = false, FixtureDecisionOutside);
    PENDING_REFUSAL("replacement with owned paths cannot inherit role",
                    sample.first.seconds++; sample.second.seconds++;
                    sample.firstScope = FixtureScopeOwned; sample.secondScope = FixtureScopeOwned;
                    sample.firstKernelESRCH = false; sample.secondKernelESRCH = false, FixtureDecisionOwned);
    PENDING_REFUSAL("first identity changes before final absence", sample.first.seconds++; sample.secondLookup = FixtureLookupGone, FixtureDecisionGone);
    PENDING_REFUSAL("first metadata unknown before final absence", sample.firstLookup = FixtureLookupUnknown; sample.secondLookup = FixtureLookupGone, FixtureDecisionUnknown);
    PENDING_REFUSAL("final metadata unknown after first absence", sample.firstLookup = FixtureLookupGone; sample.secondLookup = FixtureLookupUnknown, FixtureDecisionUnknown);
    PENDING_REFUSAL("first metadata permission failure", sample.firstLookup = FixtureLookupUnknown, FixtureDecisionUnknown);
    PENDING_REFUSAL("final metadata partial read", sample.secondLookup = FixtureLookupUnknown, FixtureDecisionUnknown);
    PENDING_REFUSAL("invalid first metadata enum", sample.firstLookup = (enum FixtureLookup)99, FixtureDecisionUnknown);
    PENDING_REFUSAL("first absence then same present identity refuses", sample.firstLookup = FixtureLookupGone, FixtureDecisionChanged);
    PENDING_REFUSAL("first absence then replacement identity refuses", sample.firstLookup = FixtureLookupGone; sample.second.seconds++, FixtureDecisionChanged);
    PENDING_REFUSAL("first real UID drift", sample.first.ruid++, FixtureDecisionUnknown);
    PENDING_REFUSAL("second real UID drift", sample.second.ruid = 0, FixtureDecisionUnknown);
    PENDING_REFUSAL("first effective UID drift", sample.first.euid = 0, FixtureDecisionUnknown);
    PENDING_REFUSAL("second effective UID drift", sample.second.euid++, FixtureDecisionUnknown);
    PENDING_REFUSAL("UID drift cannot be hidden by final absence", sample.first.ruid++; sample.secondLookup = FixtureLookupGone, FixtureDecisionGone);
    PENDING_REFUSAL("UID drift cannot be hidden by final zombie", sample.second.ruid++; sample.second.zombie = true, FixtureDecisionGone);
    PENDING_REFUSAL("outside recovery still rejects pinned UID drift",
                    sample.first.ruid++; sample.second.ruid++;
                    sample.firstScope = FixtureScopeOutside; sample.secondScope = FixtureScopeOutside;
                    sample.firstKernelESRCH = false; sample.secondKernelESRCH = false, FixtureDecisionOutside);
    PENDING_REFUSAL("first path permission failure after pending", sample.firstKernelESRCH = false, FixtureDecisionUnknown);
    PENDING_REFUSAL("second path realpath ESRCH after pending", sample.secondKernelESRCH = false, FixtureDecisionUnknown);
    PENDING_REFUSAL("different path error cannot hide behind final BSD absence",
                    sample.firstKernelESRCH = false; sample.secondLookup = FixtureLookupGone, FixtureDecisionGone);
    PENDING_REFUSAL("different path error cannot hide behind final zombie",
                    sample.secondKernelESRCH = false; sample.second.zombie = true, FixtureDecisionGone);
    PENDING_REFUSAL("one recovered path is not a full new classification", sample.firstScope = FixtureScopeOutside; sample.firstKernelESRCH = false, FixtureDecisionUnknown);
    PENDING_REFUSAL("invalid fresh path scope", sample.secondScope = (enum FixtureScope)99, FixtureDecisionUnknown);
    PENDING_REFUSAL("owned path moving outside keeps original refusal",
                    sample.firstScope = FixtureScopeOwned; sample.secondScope = FixtureScopeOutside;
                    sample.firstKernelESRCH = false; sample.secondKernelESRCH = false, FixtureDecisionChanged);
    PENDING_REFUSAL("resolved scope with contradictory kernel error refuses",
                    sample.firstScope = FixtureScopeOutside; sample.secondScope = FixtureScopeOutside, FixtureDecisionOutside);
    PENDING_REFUSAL("new known pointer cannot promote anchor", sample.known = &live, FixtureDecisionOwned);
    PENDING_REFUSAL("initial zombie becoming live does not resolve pending anchor", sample.first.zombie = true, FixtureDecisionUnknown);
    PENDING_REFUSAL("changed expected UID cannot bless credential drift",
                    sample.expectedUID++; sample.first.euid++; sample.first.ruid++;
                    sample.second.euid++; sample.second.ruid++;
                    sample.firstScope = FixtureScopeOwned; sample.secondScope = FixtureScopeOwned;
                    sample.firstKernelESRCH = false; sample.secondKernelESRCH = false, FixtureDecisionOwned);
    PENDING_REFUSAL("root expected UID cannot resolve pending disappearance", sample.expectedUID = 0; sample.secondLookup = FixtureLookupGone, FixtureDecisionGone);
#undef PENDING_REFUSAL
}

static void testPathRetryGlobalLimits(void) {
    const struct FixtureProcess live = {77, 501, 501, 100, 12, false};
    struct FixturePathRetryState state = {0};
    struct FixturePathRetryBudget budget = FixtureMakePathRetryBudget(100);
    for (unsigned i = 0; i < FIXTURE_PATH_RETRY_LIMIT; i++)
        enterPathRetry(&state, &budget, live, 100 + i * FIXTURE_PATH_RETRY_DELAY_NS);
    check(budget.remaining == 0, "six retries consume shared count exactly");
    checkRetry(observeRetry(&state, &budget, missingPaths(live),
        100 + FIXTURE_PATH_RETRY_LIMIT * FIXTURE_PATH_RETRY_DELAY_NS, FixtureDecisionUnknown,
        "last reserved observation remains unresolved"), FixturePathRetryRefuse, "seventh delay is never permitted");
    check(state.pending, "exhausted unknown still blocks snapshot completion");

    // The final already-reserved observation is allowed to resolve affirmatively.
    state = (struct FixturePathRetryState){0};
    budget = FixtureMakePathRetryBudget(100);
    for (unsigned i = 0; i < FIXTURE_PATH_RETRY_LIMIT; i++)
        enterPathRetry(&state, &budget, live, 100 + i * FIXTURE_PATH_RETRY_DELAY_NS);
    struct RetryObservation recovered = missingPaths(live);
    recovered.firstScope = FixtureScopeOutside; recovered.secondScope = FixtureScopeOutside;
    recovered.firstKernelESRCH = false; recovered.secondKernelESRCH = false;
    checkRetry(observeRetry(&state, &budget, recovered,
        100 + FIXTURE_PATH_RETRY_LIMIT * FIXTURE_PATH_RETRY_DELAY_NS, FixtureDecisionOutside,
        "sixth fresh observation can resolve"), FixturePathRetryAccept, "reserved final sample accepted without another delay");

    // New process states do not create fresh time or delay budgets.
    budget = FixtureMakePathRetryBudget(100);
    for (unsigned i = 0; i < FIXTURE_PATH_RETRY_LIMIT; i++) {
        struct FixtureProcess process = live; process.pid += i;
        state = (struct FixturePathRetryState){0};
        uint64_t now = 100 + i * FIXTURE_PATH_RETRY_DELAY_NS;
        enterPathRetry(&state, &budget, process, now);
        struct RetryObservation gone = missingPaths(process); gone.secondLookup = FixtureLookupGone;
        checkRetry(observeRetry(&state, &budget, gone, now + FIXTURE_PATH_RETRY_DELAY_NS,
            FixtureDecisionGone, "different process resolves within shared invocation"),
            FixturePathRetryAccept, "process resolution does not replenish budget");
    }
    state = (struct FixturePathRetryState){0};
    checkRetry(observeRetry(&state, &budget, missingPaths(live), budget.last_ns,
        FixtureDecisionUnknown, "seventh process has no new budget"), FixturePathRetryRefuse,
        "six global delays cannot become six per process");
    check(!state.pending && budget.start_ns == 100 && budget.deadline_ns == 100 + FIXTURE_PATH_RETRY_WINDOW_NS,
          "new process does not pin anchor without delay or extend fixed deadline");

    state = (struct FixturePathRetryState){0}; budget = FixtureMakePathRetryBudget(100);
    enterPathRetry(&state, &budget, live, 100);
    checkRetry(observeRetry(&state, &budget, recovered, 100 + FIXTURE_PATH_RETRY_DELAY_NS,
        FixtureDecisionOutside, "first process resolves while global time runs"),
        FixturePathRetryAccept, "first process does not reset time");
    state = (struct FixturePathRetryState){0};
    checkRetry(observeRetry(&state, &budget, missingPaths(live), budget.deadline_ns - FIXTURE_PATH_RETRY_DELAY_NS,
        FixtureDecisionUnknown, "next process arrives too late in same invocation"),
        FixturePathRetryRefuse, "new process cannot obtain a new one-second window");
    check(budget.remaining == FIXTURE_PATH_RETRY_LIMIT - 1,
          "global time budget expires even while delay tokens remain");

    const uint64_t badTimes[] = {99, 100 + FIXTURE_PATH_RETRY_WINDOW_NS,
                                 100 + FIXTURE_PATH_RETRY_WINDOW_NS + 1};
    for (size_t i = 0; i < sizeof(badTimes) / sizeof(badTimes[0]); i++) {
        state = (struct FixturePathRetryState){0}; budget = FixtureMakePathRetryBudget(100);
        enterPathRetry(&state, &budget, live, 100);
        checkRetry(observeRetry(&state, &budget, recovered, badTimes[i], FixtureDecisionOutside,
            "outside recovery has invalid observation time"), FixturePathRetryRefuse,
            "recovery cannot bypass backwards or expired clock");
        check(state.pending, "time refusal retains unresolved anchor");
    }
    state = (struct FixturePathRetryState){0}; budget = FixtureMakePathRetryBudget(100);
    enterPathRetry(&state, &budget, live, 100);
    enterPathRetry(&state, &budget, live, 100 + FIXTURE_PATH_RETRY_DELAY_NS);
    checkRetry(observeRetry(&state, &budget, recovered, 99 + FIXTURE_PATH_RETRY_DELAY_NS,
        FixtureDecisionOutside, "clock moves backwards but stays above initial start"),
        FixturePathRetryRefuse, "latest observation floor detects intra-window backwards clock");

    state = (struct FixturePathRetryState){0}; budget = FixtureMakePathRetryBudget(100);
    uint64_t latestDelay = budget.deadline_ns - FIXTURE_PATH_RETRY_DELAY_NS;
    checkRetry(observeRetry(&state, &budget, missingPaths(live), latestDelay, FixtureDecisionUnknown,
        "only exact delay remains"), FixturePathRetryRefuse, "delay must leave time for fresh sample");
    check(!state.pending && budget.remaining == FIXTURE_PATH_RETRY_LIMIT,
          "insufficient remaining time spends no delayed retry");
    state = (struct FixturePathRetryState){0}; budget = FixtureMakePathRetryBudget(100);
    enterPathRetry(&state, &budget, live, latestDelay - 1);
    check(FixturePathRetryWithinBudget(&budget, budget.deadline_ns - 1), "delayed check still inside exclusive deadline");
    check(!FixturePathRetryWithinBudget(&budget, budget.deadline_ns), "delayed oversleep refused before fresh native sample");
    checkRetry(observeRetry(&state, &budget, recovered, budget.deadline_ns, FixtureDecisionOutside,
        "sample itself consumed remaining time"), FixturePathRetryRefuse, "late sampled result never accepted");

    state = (struct FixturePathRetryState){0}; budget = FixtureMakePathRetryBudget(UINT64_MAX);
    checkRetry(observeRetry(&state, &budget, missingPaths(live), UINT64_MAX, FixtureDecisionUnknown,
        "overflowed initial budget stays unknown"), FixturePathRetryRefuse, "overflow cannot enter retry controller");
}

int main(void) {
    testNormalUser();
    testIdentity();
    testPaths();
    testClassify();
    testRecheck();
    testPathRetryBudget();
    testPathRetryInitialEligibility();
    testPathRetryResolution();
    testPathRetryPendingRefusals();
    testPathRetryGlobalLimits();
    printf("probe policy: %zu cases passed\n", casesRun);
    return 0;
}
