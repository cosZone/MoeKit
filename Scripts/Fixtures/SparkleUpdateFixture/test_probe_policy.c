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

int main(void) {
    testNormalUser();
    testIdentity();
    testPaths();
    testClassify();
    testRecheck();
    printf("probe policy: %zu cases passed\n", casesRun);
    return 0;
}
