# Processes & Ports: read-only milestone

This module is an on-demand, local, native macOS inventory. It does not stop a process, launch a command, create a background daemon, poll periodically, or infer that a process is abandoned. The stop-plan sheet is an inspection artifact only; no signal executor exists.

## What is observed

- Readable processes owned by the current effective user; system-wide enumeration is used only to identify that subset
- PID, kernel start timestamp (seconds and microseconds), UID, executable path, process name, parent PID and process group
- Current working directory and TCP listening socket endpoints, when readable
- Explicit capture time, partial coverage, per-row metadata limits, and unknown values

Raw arguments, environment variables, remote socket endpoints, cookies, browser profiles and project contents are not inspected. CPU and memory sampling are not included; this is not a full Activity Monitor replacement. A complete empty TCP listener list means no listener was observed during that per-process descriptor pass, not that the process has no network connections.

Native APIs are bounded by process count, descriptor count and a cooperative wall-clock budget. Individual kernel/path reads are synchronous and cannot be interrupted mid-call. Metadata reads race with process exit, exec, reparenting and socket changes; identities are checked before/after a row, but the entire snapshot is not atomic. Denied or changing rows produce incomplete coverage rather than fabricated zero values. Permission restrictions are not bypassed and the app never requests root.

## Project associations

Canonical current working directory containment in an already-added project is observed evidence only. Component boundaries prevent sibling-prefix matches. The deepest unique project root wins; duplicate canonical roots and missing/ambiguous paths remain unattributed. A project at filesystem root is not used for association. Parent PID, process name, port, old age, PPID 1, or a missing parent do not establish ownership. No process is labeled “Started by MoeKit” because this milestone has no launch ledger.

Browser/GUI-app, IDE, shell, database, VM and shared-service hints are highlighted for individual review. These conservative heuristics are not an exhaustive safety guarantee. In particular, a Chrome helper cannot be assumed to be a disposable automation instance. Process groups are never treated as exclusive sessions.

## Inspection plan, not execution

The plan preserves exactly the selected identities and their metadata. It never expands a selection to parents, children, or a process group. Changing the visible selection, search, project filter, scan or Demo mode invalidates the open preview. A pure revalidation model covers stale/future snapshots, PID reuse, observed executable-path changes, UID changes, changing metadata, missing processes, selection changes and incomplete snapshots. Its outcome is never permission to signal a PID. A same-path re-exec is not detected by PID/start-time/UID/path comparison; a future executor needs additional exec-generation evidence and cannot use this model alone.

Any future executor needs independent review: recompute protections, parent availability and shared-group/dependency risks from the entire fresh snapshot (the pure identity comparison only checks selected records and observer context); fresh identity and ownership checks; exact positive targets; cooperative shutdown before termination; per-target results and observed exits; separately confirmed force escalation; no kill-by-name, negative process-group targets, privileged helper or automatic cleanup. Rechecking a PID identity does not eliminate the check-to-signal race.

## Lifetime and privacy

Snapshot/selection/preview data lives only in memory and is cleared across Demo-mode changes. Demo mode never scans or shows a real process snapshot. Task entries retain only scan status and a count, not process names, executable paths or arguments. No process history is persisted or uploaded. Projects → Related processes opens a filtered view; it does not scan implicitly.

## Verification

Synthetic tests cover association boundaries, partial metadata, protected classifications, PID reuse, stale selection, changed process metadata, scan cancellation and mode boundaries. Provider parsing tests use synthetic native structures and never inspect user processes. Native compilation and full Swift tests require the exact branch commit's macOS CI. UI layout, VoiceOver, real libproc coverage/permissions and Intel/Apple Silicon behavior still require manual native acceptance; fixture success must not be represented as those checks.

Behavior references, used for ideas rather than copied code: [WhatThePort](https://github.com/tomjohndesign/what-the-port), [proc-janitor](https://github.com/jhlee0409/proc-janitor), [Worktrunk tether](https://worktrunk.dev/step/#wt-step-tether). API references: [Apple libproc declarations](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.h) and [process/socket structures](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info.h). Validate the target SDK: Apple's source notes that libproc interfaces can change.
