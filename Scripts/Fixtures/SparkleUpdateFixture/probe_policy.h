// Original, portable policy for the read-only CI fixture lifetime probe.
// No process lookup, filesystem access, signaling, or installation occurs here.
#ifndef MOEKIT_SPARKLE_FIXTURE_PROBE_POLICY_H
#define MOEKIT_SPARKLE_FIXTURE_PROBE_POLICY_H

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

enum FixtureScope {
    FixtureScopeUnknown,
    FixtureScopeOutside,
    FixtureScopeOwned
};

enum FixtureLookup {
    FixtureLookupPresent,
    FixtureLookupGone,
    FixtureLookupUnknown
};

struct FixtureProcess {
    uint32_t pid, euid, ruid;
    uint64_t seconds, microseconds;
    bool zombie;
};

enum FixtureDecision {
    FixtureDecisionOutside,
    FixtureDecisionOwned,
    FixtureDecisionGone,
    FixtureDecisionChanged,
    FixtureDecisionUnknown
};

static inline bool FixtureNormalUser(uint32_t realUID, uint32_t effectiveUID) {
    return realUID != 0 && realUID == effectiveUID;
}

// Credentials are deliberately separate from PID/start identity: a credential
// change must not make a known, still-live process disappear from the inventory.
static inline bool FixtureSameIdentity(struct FixtureProcess a, struct FixtureProcess b) {
    return a.pid == b.pid && a.seconds == b.seconds && a.microseconds == b.microseconds;
}

static inline bool FixtureCanonicalPath(const char *path) {
    if (!path || path[0] != '/') return false;
    if (path[1] == '\0') return true;
    const char *component = path + 1;
    for (const char *cursor = component; ; cursor++) {
        if (*cursor == '/' || *cursor == '\0') {
            size_t length = (size_t)(cursor - component);
            if (length == 0 || (length == 1 && component[0] == '.') ||
                (length == 2 && component[0] == '.' && component[1] == '.')) return false;
            if (*cursor == '\0') return true;
            component = cursor + 1;
        }
    }
}

static inline bool FixturePathWithin(const char *path, const char *root) {
    size_t length = strlen(root);
    return (length == 1 && root[0] == '/') ||
        (strncmp(path, root, length) == 0 && (path[length] == '\0' || path[length] == '/'));
}

// The caller must first physically resolve paths (or resolve a known canonical
// parent plus its missing leaf). Lexical validation does not resolve symlinks.
static inline enum FixtureScope FixturePathScope(const char *physicalPath,
                                                 const char *root, const char *cache) {
    if (!FixtureCanonicalPath(physicalPath) || !FixtureCanonicalPath(root) ||
        !FixtureCanonicalPath(cache)) return FixtureScopeUnknown;
    return FixturePathWithin(physicalPath, root) || FixturePathWithin(physicalPath, cache)
        ? FixtureScopeOwned : FixtureScopeOutside;
}

static inline bool FixtureExpectedUser(struct FixtureProcess process, uint32_t expectedUID) {
    return expectedUID != 0 && process.euid == expectedUID && process.ruid == expectedUID;
}

static inline enum FixtureDecision FixtureClassify(
    struct FixtureProcess first, struct FixtureProcess second,
    enum FixtureLookup firstLookup, enum FixtureLookup secondLookup,
    enum FixtureScope firstScope, enum FixtureScope secondScope,
    uint32_t expectedUID, const struct FixtureProcess *known) {
    // Neither an access failure nor a partial read is positive absence.
    if ((firstLookup != FixtureLookupPresent && firstLookup != FixtureLookupGone) ||
        (secondLookup != FixtureLookupPresent && secondLookup != FixtureLookupGone))
        return FixtureDecisionUnknown;
    if (secondLookup == FixtureLookupGone) return FixtureDecisionGone;
    if (firstLookup == FixtureLookupGone || !FixtureSameIdentity(first, second))
        return FixtureDecisionChanged;

    bool isKnown = known && (FixtureSameIdentity(*known, first) || FixtureSameIdentity(*known, second));
    bool hasOwnedPath = firstScope == FixtureScopeOwned || secondScope == FixtureScopeOwned;
    if ((isKnown || hasOwnedPath) &&
        (!FixtureExpectedUser(first, expectedUID) || !FixtureExpectedUser(second, expectedUID)))
        return FixtureDecisionUnknown;

    // Only the final state of a stable identity can establish a zombie. The
    // first sample being a zombie never hides a currently live process.
    if (second.zombie) return FixtureDecisionGone;
    // A known live identity stays owned after its executable is unlinked or
    // moved; paths cannot erase an identity already captured by this probe.
    if (isKnown) return FixtureDecisionOwned;
    if ((firstScope != FixtureScopeOutside && firstScope != FixtureScopeOwned) ||
        (secondScope != FixtureScopeOutside && secondScope != FixtureScopeOwned))
        return FixtureDecisionUnknown;
    if (firstScope == FixtureScopeOwned && secondScope == FixtureScopeOutside)
        return FixtureDecisionChanged;
    if (hasOwnedPath) return FixtureDecisionOwned;
    // Unrelated, positively outside executables do not become fixture-owned
    // merely because their real UID differs from the enumerating user's UID.
    return FixtureDecisionOutside;
}

static inline enum FixtureDecision FixtureRecheck(
    struct FixtureProcess known, struct FixtureProcess first, struct FixtureProcess second,
    enum FixtureLookup firstLookup, enum FixtureLookup secondLookup,
    uint32_t expectedUID, const struct FixtureProcess *finalClassified) {
    if ((firstLookup != FixtureLookupPresent && firstLookup != FixtureLookupGone) ||
        (secondLookup != FixtureLookupPresent && secondLookup != FixtureLookupGone))
        return FixtureDecisionUnknown;
    if (secondLookup == FixtureLookupGone) return FixtureDecisionGone;
    if (firstLookup == FixtureLookupGone || !FixtureSameIdentity(first, second))
        return FixtureDecisionChanged;
    // Reads must refer to the requested PID. A different PID is not evidence
    // that the requested identity disappeared.
    if (first.pid != known.pid) return FixtureDecisionUnknown;
    // The caller retains the final read of every process it fully classified,
    // including positively outside processes. A replacement first seen here
    // cannot grant idle or installation acknowledgement: it needs an ordinary
    // FixtureClassify pass in a new snapshot before the old role can be gone.
    if (!FixtureSameIdentity(known, first))
        return finalClassified && FixtureSameIdentity(*finalClassified, second)
            ? FixtureDecisionGone : FixtureDecisionChanged;
    if (!FixtureExpectedUser(first, expectedUID) || !FixtureExpectedUser(second, expectedUID))
        return FixtureDecisionUnknown;
    if (second.zombie) return FixtureDecisionGone;
    if (!finalClassified || !FixtureSameIdentity(*finalClassified, second))
        return FixtureDecisionUnknown;
    return FixtureDecisionOwned;
}

#endif
