# Processes & Ports: snapshots and confirmed stopping

This module is an on-demand, local, native macOS inventory. It never scans or stops automatically, launches arbitrary commands, creates a background daemon, or infers abandonment. A separate fresh confirmation can now stop exact eligible current-user identities.

## What is observed

- Readable processes owned by the current effective user; system-wide enumeration is used only to identify that subset
- PID, kernel start timestamp (seconds and microseconds), execution version when available, UID, executable path, process name, parent PID and process group
- Current working directory and TCP listening socket endpoints, when readable
- Explicit capture time, partial coverage, per-row metadata limits, and unknown values

Raw arguments, environment variables, remote socket endpoints, cookies, browser profiles and project contents are not inspected. CPU and memory sampling are not included; this is not a full Activity Monitor replacement. A complete empty TCP listener list means no listener was observed during that per-process descriptor pass, not that the process has no network connections.

Native APIs are bounded by process count, descriptor count and a cooperative wall-clock budget. Individual kernel/path reads are synchronous and cannot be interrupted mid-call. Metadata reads race with process exit, exec, reparenting and socket changes; identities are checked before/after a row, but the entire snapshot is not atomic. Denied or changing rows produce incomplete coverage rather than fabricated zero values. Permission restrictions are not bypassed and the app never requests root.

## Project associations

Canonical current working directory containment in an already-added project is observed evidence only. Both process working directories and catalog roots use `realpath` physical paths, preserving macOS aliases such as `/tmp` → `/private/tmp`. Component boundaries prevent sibling-prefix matches. The deepest unique project root wins; duplicate canonical roots and missing/ambiguous paths remain unattributed. A project at filesystem root is not used for association. Parent PID, process name, port, old age, PPID 1, or a missing parent do not establish ownership. No process is labeled “Started by MoeKit” because this milestone has no launch ledger.

Browser/GUI-app, IDE, shell, database, VM and shared-service hints are highlighted for individual review. These conservative heuristics are not an exhaustive safety guarantee. In particular, a Chrome helper cannot be assumed to be a disposable automation instance. Process groups are never treated as exclusive sessions.

## Review and separate execution confirmation

The inspection plan preserves only the selected identities and metadata; it is not authority to signal anything. A separate executor rereads selected targets, refuses protected/incomplete/changed targets, and creates a one-use 60-second confirmation. Confirmed graceful stop submits SIGTERM through a kernel audit token; only a still-running exact identity can get a separate confirmed SIGKILL review. Names, groups, parents and children never expand targets. Signal submission does not prove exit, and a target's own shutdown can affect dependent work.

Browser/app, shared-service, system, self and ancestor protections fail closed. Dedicated headless browser sessions remain unsupported because current evidence cannot establish ownership. No argv/environment/profile collection or privilege expansion is introduced. See [identity mechanism, limits and tests](Process-termination-design.md).

## Lifetime and privacy

Snapshot/selection/preview data lives only in memory and is cleared across Demo-mode changes. Demo mode never scans or shows a real process snapshot. Task entries retain only scan status and a count, not process names, executable paths or arguments. No process history is persisted or uploaded. Projects → Related processes opens a filtered view; it does not scan implicitly.

## Verification

Synthetic tests cover association boundaries, partial metadata, protected classifications, PID reuse, stale selection, changed process metadata, scan cancellation and mode boundaries. Provider parsing tests use synthetic native structures and never inspect user processes. Native compilation and full Swift tests require the exact branch commit's macOS CI. UI layout, VoiceOver, real libproc coverage/permissions and Intel/Apple Silicon behavior still require manual native acceptance; fixture success must not be represented as those checks.

Behavior references, used for ideas rather than copied code: [WhatThePort](https://github.com/tomjohndesign/what-the-port), [proc-janitor](https://github.com/jhlee0409/proc-janitor), [Worktrunk tether](https://worktrunk.dev/step/#wt-step-tether). API references: [Apple libproc declarations](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.h) and [process/socket structures](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info.h). Validate the target SDK: Apple's source notes that libproc interfaces can change.

## Reading and narrowing a snapshot

The port-coverage control separates **All processes**, **TCP listeners**, and **Unknown ports**. Confirmed-empty listener arrays are not treated as unknown, and unknown arrays are never treated as confirmed-empty. Counts use the current search and project filter before the port filter, and search includes only already-observed names, paths, PIDs and local listening endpoints. The unknown filter is not a count of unreadable processes omitted from a partial snapshot. Empty filtered results do not prove that a port is available.

Association details distinguish unreadable/unresolved working directories, no usable project roots, working directories outside those roots, and ambiguous canonical aliases. An observed association displays the matched canonical project folder beside the process's working directory. Roots that could not be resolved are counted separately from process metadata coverage. Refresh is needed after catalog or filesystem changes; this evidence belongs to the captured snapshot.

A refresh clears the old selection and inspection plan. The previous snapshot stays visible with an explicit notice during refresh and after cancellation/failure, and a successful scan replaces it. Selection in the table is disabled during a scan. Cancelled and failed first scans have distinct empty states; a late result/error from cancelled work cannot replace the current state. Port/search/project filter changes constrain selection and invalidate the inspection plan; clearing filters never selects additional targets.

The plan counts protected targets separately from other review warnings and retains exact association evidence. Protection flags are conservative hints, not authorization to stop other targets. Stopping adds no ownership assertion, argv/environment inspection or background scanning. It requires its own fresh confirmation after inspection.

Manual native acceptance still required: use synthetic/approved fixtures to check the port control and local-address search; cancel both first and refresh scans; retry after a provider error; confirm old rows carry their old timestamp; change filters with an open plan; switch Demo modes while scanning; check narrow-window layout and VoiceOver names. Automated fixture tests do not establish real libproc permission coverage or visual acceptance.
