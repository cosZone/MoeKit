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

// These limits are shared by all process observations in one native probe
// invocation. A retry is another complete metadata/path/path/metadata sample,
// never a replacement for FixtureClassify or evidence of idle/acknowledgement.
#define FIXTURE_PATH_RETRY_WINDOW_NS UINT64_C(1000000000)
#define FIXTURE_PATH_RETRY_DELAY_NS UINT64_C(20000000)
#define FIXTURE_PATH_RETRY_LIMIT 6u

enum FixturePathRetryAction {
    FixturePathRetryAccept,
    FixturePathRetryAgain,
    FixturePathRetryRefuse
};

struct FixturePathRetryBudget {
    // The invocation start/deadline never move. The last accepted clock
    // reading detects backwards time between observations.
    uint64_t start_ns, deadline_ns, last_ns;
    unsigned remaining;
};

struct FixturePathRetryState {
    bool pending;
    // This unresolved identity is only an anchor, never a known/owned role.
    struct FixtureProcess anchor;
};

static inline struct FixturePathRetryBudget FixtureMakePathRetryBudget(uint64_t now) {
    struct FixturePathRetryBudget budget = {now, 0, now, 0};
    if (now <= UINT64_MAX - FIXTURE_PATH_RETRY_WINDOW_NS) {
        budget.deadline_ns = now + FIXTURE_PATH_RETRY_WINDOW_NS;
        budget.remaining = FIXTURE_PATH_RETRY_LIMIT;
    }
    return budget;
}

// Reserved retries may still complete when remaining is zero. This check is
// also used after sleeping and before the native caller reads fresh metadata.
static inline bool FixturePathRetryWithinBudget(const struct FixturePathRetryBudget *budget,
                                                uint64_t now) {
    return budget && budget->start_ns < budget->deadline_ns &&
        budget->last_ns >= budget->start_ns && budget->last_ns < budget->deadline_ns &&
        now >= budget->last_ns && now < budget->deadline_ns;
}

static inline enum FixturePathRetryAction FixturePathRetryObserve(
    struct FixturePathRetryState *state, struct FixturePathRetryBudget *budget,
    struct FixtureProcess first, struct FixtureProcess second,
    enum FixtureLookup firstLookup, enum FixtureLookup secondLookup,
    enum FixtureScope firstScope, enum FixtureScope secondScope,
    const struct FixtureProcess *known, enum FixtureDecision decision,
    bool firstKernelESRCH, bool secondKernelESRCH, uint32_t expectedUID, uint64_t now) {
    if (!state || !budget) return FixturePathRetryRefuse;
    // The controller never synthesizes a classification or changes its meaning.
    if (decision != FixtureClassify(first, second, firstLookup, secondLookup,
                                   firstScope, secondScope, expectedUID, known))
        return FixturePathRetryRefuse;
    if (!state->pending && decision != FixtureDecisionUnknown)
        return FixturePathRetryAccept;
    if (!FixturePathRetryWithinBudget(budget, now)) return FixturePathRetryRefuse;
    budget->last_ns = now;

    bool bothPresent = firstLookup == FixtureLookupPresent && secondLookup == FixtureLookupPresent;
    bool bothKernelMissing = firstScope == FixtureScopeUnknown && secondScope == FixtureScopeUnknown &&
        firstKernelESRCH && secondKernelESRCH;
    bool bothPathsResolved =
        (firstScope == FixtureScopeOutside || firstScope == FixtureScopeOwned) &&
        (secondScope == FixtureScopeOutside || secondScope == FixtureScopeOwned) &&
        !firstKernelESRCH && !secondKernelESRCH;

    if (state->pending) {
        // A new known pointer must not turn the unowned anchor into ownership.
        // Access/partial metadata errors never establish disappearance.
        if (known || !FixtureExpectedUser(state->anchor, expectedUID) ||
            (firstLookup != FixtureLookupPresent && firstLookup != FixtureLookupGone) ||
            (secondLookup != FixtureLookupPresent && secondLookup != FixtureLookupGone) ||
            (firstLookup == FixtureLookupGone && secondLookup == FixtureLookupPresent))
            return FixturePathRetryRefuse;
        if ((firstLookup == FixtureLookupPresent &&
             (!FixtureSameIdentity(state->anchor, first) || !FixtureExpectedUser(first, expectedUID))) ||
            (secondLookup == FixtureLookupPresent &&
             (!FixtureSameIdentity(state->anchor, second) || !FixtureExpectedUser(second, expectedUID))))
            return FixturePathRetryRefuse;
        // If paths were attempted, a new error stage must not be erased by
        // later disappearance. Valid resolved scope or exact kernel ESRCH is
        // acceptable provenance; skipped path reads do not create an error.
        if (firstLookup == FixtureLookupPresent && !first.zombie &&
            !(((firstScope == FixtureScopeOutside || firstScope == FixtureScopeOwned) && !firstKernelESRCH) ||
              (firstScope == FixtureScopeUnknown && firstKernelESRCH)))
            return FixturePathRetryRefuse;
        if (firstLookup == FixtureLookupPresent && !first.zombie &&
            !(((secondScope == FixtureScopeOutside || secondScope == FixtureScopeOwned) && !secondKernelESRCH) ||
              (secondScope == FixtureScopeUnknown && secondKernelESRCH)))
            return FixturePathRetryRefuse;
        if (decision == FixtureDecisionGone) {
            state->pending = false;
            return FixturePathRetryAccept;
        }
        if (bothPresent && !first.zombie && !second.zombie && bothPathsResolved &&
            (decision == FixtureDecisionOutside || decision == FixtureDecisionOwned)) {
            state->pending = false;
            return FixturePathRetryAccept;
        }
    }

    // Only proc_pidpath itself returning ESRCH twice is retryable. The caller
    // must not set these booleans for realpath failures, permissions or partial
    // path reads. Unknown scope alone is deliberately insufficient.
    if (known || decision != FixtureDecisionUnknown || !bothPresent || !first.pid || !second.pid ||
        !FixtureSameIdentity(first, second) || !FixtureExpectedUser(first, expectedUID) ||
        !FixtureExpectedUser(second, expectedUID) || first.zombie || second.zombie || !bothKernelMissing)
        return FixturePathRetryRefuse;
    // A whole delay and time for a subsequent sample must remain. Subtraction
    // is safe because the deadline and current clock were checked above.
    if (!budget->remaining || budget->deadline_ns - now <= FIXTURE_PATH_RETRY_DELAY_NS)
        return FixturePathRetryRefuse;
    if (!state->pending) {
        state->anchor = first;
        state->pending = true;
    }
    budget->remaining--;
    return FixturePathRetryAgain;
}

#endif
