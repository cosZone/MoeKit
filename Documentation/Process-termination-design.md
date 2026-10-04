# Confirmed exact-process termination

This increment implements real selected-process `SIGTERM` and a separate `SIGKILL` confirmation. It does not yet solve ownership attribution for abandoned AI browser sessions. Browser/app/IDE/database/VM/shared-service hints remain protected because cwd, PPID, age and ports cannot prove a dedicated headless browser instance. It reads no arguments, environment or browser profiles.

## Confirmation contract

1. A user explicitly scans, selects 1–16 exact records, and reviews every identity, executable path, working directory, local TCP listener, protection and association warning. No target is selected by default or added by name, group, ancestry or project association.
2. Prepare rereads only selected PIDs and requires exact records, complete target metadata, current-user ownership, a kernel execution version and no protected target. Root/set-ID execution is refused. MoeKit and its ancestors are refused through a bounded freshly read ancestor chain; an unreadable chain fails closed.
3. A private actor mints an in-memory nonce with a 60-second monotonic expiry. The UI displays exact targets, signal and possible unsaved-work/dependency consequences; a consequence acknowledgement and destructive confirmation button are required. No Enter default accepts it. Dismiss, refresh, selection/filter changes or mode changes cancel pending authority.
4. Execute consumes the nonce before any suspension. It preflights the whole selection, then rereads each target immediately before its signal. Any changed/missing identity, executable version, owner, name, cwd, parent/group, listener or metadata state refuses that target. No retry is automatic. A batch is not atomic; per-target outcomes show partial submission.
5. `SIGTERM` is sent only through `proc_signal_with_audittoken`. A successful return is signal submission, not proof of exit. Bounded observation reports identity exited, still running, or unknown. There is no signal 0 probe, group kill, kill-by-name, PID-only fallback, launch daemon, privilege prompt or automatic force escalation.
6. Only an exact identity still observed after a submitted graceful stop is eligible to prepare force stop. Fresh checks, a new nonce, another consequence acknowledgement and a separate destructive confirmation precede `SIGKILL`. Cancelled force confirmation does not send a signal. A changed execution must be scanned and gracefully reviewed anew.

Signals may cause a target's own shutdown handler to affect its children or external work; sending to one PID cannot promise that its program has no secondary effects. The confirmation says so. Unflagged rows are not proof of safety or exclusive ownership.

## Native identity mechanism and limits

`task_name_for_pid` provides a task-name right, not a task-control right. `task_info(TASK_AUDIT_TOKEN)` reads a kernel-issued token and the name right is immediately released. The inventory sandwiches BSD/path observations with token reads and retains the execution version. Required token acquisition failures block stopping; they do not request additional access.

`proc_signal_with_audittoken` is used by its declaration in the macOS SDK's libproc header. There is no copied private structure, private selector number, raw syscall, runtime symbol lookup or alternate signal API. macOS 15 / Xcode 16.4 compilation and native fixtures are explicit release gates; source-only checks do not establish support. Apple's libproc header warns these interfaces are version-sensitive. This is direct-distribution software; no App Store compatibility claim is made.

Apple's macOS 15-era XNU implementation resolves an audit token's PID and execution version, checks normal signal permission, and retains/reacquires the matching process identity before signaling. This addresses numeric PID reuse and stale exec-generation targeting. It does not make prior cwd, listener, parent, dependency or application state reads atomic. Cooperative budgets cannot interrupt a kernel call; metadata changes after the final checks remain possible. No claim of a globally race-free snapshot or behavior is made.

Primary references (implementation is original):
- [libproc declaration](https://github.com/apple-oss-distributions/xnu/blob/xnu-11417.140.69/libsyscall/wrappers/libproc/libproc.h)
- [libproc signal wrapper and return convention](https://github.com/apple-oss-distributions/xnu/blob/xnu-11417.140.69/libsyscall/wrappers/libproc/libproc.c)
- [Kernel audit-token signal path](https://github.com/apple-oss-distributions/xnu/blob/xnu-11417.140.69/bsd/kern/proc_info.c)
- [PID/version identity lookup](https://github.com/apple-oss-distributions/xnu/blob/xnu-11417.140.69/bsd/kern/kern_proc.c)
- [Task name right and TASK_AUDIT_TOKEN handling](https://github.com/apple-oss-distributions/xnu/blob/xnu-11417.140.69/osfmk/kern/task.c)

## Tests and acceptance

Pure/coordinator tests cover one-use authority, expiry, cancellation, stale/partial/changed state, protected targets, exact per-target results, repeated confirm, and separate force authority. Native tests compile an inert original helper in a unique temporary directory, launch/reap only owned helpers, deliberately re-exec the same helper path, reject stale execution tokens, perform actual TERM/KILL, and verify an unselected same-name neighbor survives. Cleanup itself validates fixture birth/path and uses audit-token signals; no PID-only emergency fallback exists.

Native tests run with ordinary Xcode tests, including optimized Release. They are not user-Mac testing or evidence that every current-user process will allow a task-name token. Manual narrow-window, long-path, VoiceOver, language, cancellation/mode-change and real-permission acceptance remains separate. Process details and results remain in session memory; no process metadata is persisted or uploaded.
