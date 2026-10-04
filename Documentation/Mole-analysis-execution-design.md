# Mole analysis: fixed-code execution design

Status: implementation under review; this branch adds an explicit analysis entry point. A released build is not implied. Exact-commit macOS verification and independent review are required before merging or shipping.

## Deliberate boundary

The first executable operation is one ordinary-directory analysis by the unmodified, exact pinned upstream Mole V1.57.0 analyzer. It is not `mo`, a shell command, a package manager, a cleanup command, an arbitrary executable selector, or a general plug-in host. Report import stays separate.

The analyzer runs with the user's ordinary permissions. This is **not an OS sandbox** and does not promise that all incidental filesystem metadata reads remain below the selected directory. The trust boundary is the reviewed upstream code at `6bca4812acd6a3d54ffe97291734c3556a174057`, exact executable bytes, fixed argv/environment, explicit confirmation, and a bounded owned process lifecycle. No source from Mole is copied into this repository and no Mole executable is bundled with MoeKit.

The main invariant is no user-target mutation or deletion. The audited ordinary JSON path calls scanning, `du`, and `mdfind`; interactive cleanup/Finder/open operations are not reachable with the fixed invocation. Cache writes, expiry and pruning are real side effects and run only inside a fresh private HOME created by MoeKit for this invocation. Existing `~/.cache/mole` is neither read nor modified.

## Reviewed invocation and provenance

- The user chooses the direct installed analyzer binary and one directory. Neither selection starts execution. The `mo` shell wrapper is rejected without executing it. No version/help probe runs.
- Only these official upstream release assets are admissible, as published at <https://github.com/tw93/Mole/releases/tag/V1.57.0>:
  - arm64: `analyze-darwin-arm64`, 3,827,474 bytes; SHA-256 `62c6b5076349081a34e60256a1471979f600d74d8f4990745a37d30d6faa00e1`
  - x86_64: `analyze-darwin-amd64`, 4,022,992 bytes; SHA-256 `cff7d9da8bd18cb3364d566186944b5b14b01e21e5bb4a3d61579f553ea39ad7`
- A descriptor-based, non-following bounded read checks regular-file type, file identity, permissions, exact bytes and quarantine. Quarantined or changed binaries fail closed. No quarantine removal, re-signing, Gatekeeper override or automatic download/update/install exists.
- With explicit confirmation, the original executable bytes and security xattrs are copied into a private session directory, verified again, and executed there; this removes the source-path replacement window. The executable's embedded signature is not changed. A temporary copy is disclosed, not silently described as the installed path being executed in place.
- Fixed argv is `["--json", absoluteSelectedDirectory]`. No overview, interactive mode, command string, `MO_ANALYZE_PATH`, inherited `MOLE_*`, inherited `DYLD_*`, user PATH, shell, custom options or configuration file is accepted.
- Environment starts empty and supplies only reviewed fixed values: private HOME/TMPDIR, `LC_ALL=C`, `PATH=/usr/bin:/bin`, and bounded Go runtime settings. The two reachable helper basenames resolve to macOS-owned `/usr/bin/du` and `/usr/bin/mdfind`; no project helper or user executable is searched.
- A fresh HOME changes Mole's special-case home exclusions. Results describe this invocation's filtered scope, not necessarily the output of a terminal invocation with the real HOME.

## Confirmation and report semantics

The confirmation shows the selected canonical directory, pinned version/hash, executable source, private session location and limits. It explicitly discloses ordinary user permissions, target-read intent, private executable/cache/temp creation and cleanup, and no cleanup/deletion operation on selected content. Cancel or closing the confirmation creates no process.

Each request binds the directory identity and executable observation. Both are checked again at execution. Root-directory/overview requests, scope/cache overlap, stale selections, invalid paths and unsupported versions fail closed.

Completed stdout must be bounded, decode successfully, be non-overview, match the selected root exactly, and contain only canonical direct-child entry paths and descendant large-file paths. Unknown coverage is rejected for live execution, although it remains supported for imports. Duplicates, invalid paths, scope escapes and changed/symlink result identities cannot be shown as a successful live report. Partial or unavailable coverage remains visibly partial/unavailable; it is never silently upgraded to complete. The report is a non-atomic upstream filtered observation, not physical disk use or reclaimable space.

## Owned lifecycle and cleanup

A bundled original supervisor owns exactly one analyzer child and its dedicated process group. It retains the child PID while group termination is requested, so PID reuse cannot redirect cancellation. It never finds/signals arbitrary processes by name, parentage or unrelated PID. Cancellation, app pipe closure, timeout, output overflow and abnormal exit are terminal and cannot publish a successful report. The supervisor reaps its direct child; it requests SIGKILL for remaining owned group members and drains inherited pipes. It cannot waitpid grandchildren. Synthetic native tests must verify no group helper remains running, and it reports precise terminal failure. It passes closed stdin to the analyzer; interactive input cannot be supplied.

Limits include stdout, stderr, elapsed time and CPU time. Child helpers inherit applicable resource limits. Resource limits must be tested for the real Go binary; unsupported hard bounds are documented, never invented. Work runs off MainActor; generation/selection/Demo changes discard stale results and hold ownership until cleanup finishes.

Only app-created, descriptor-anchored session files may be removed. Cleanup verifies identities, does not follow symlinks, and refuses uncertainty. No broad path-based recursive removal, user cache pruning or target deletion is implemented by MoeKit.

## Why App Sandbox is not claimed

Apple documents that user-selected access does not grant external executable launch, and that spawned helpers inherit static entitlements rather than dynamic PowerBox rights. The unmodified Go analyzer cannot consume Cocoa bookmarks. A speculative XPC wrapper therefore is not sufficient proof of confinement. We do not use private sandbox APIs, deprecated `sandbox-exec` profiles, entitlement expansion, re-signing third-party executables, or claim the existing unsandboxed app is sandboxed.

- <https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox>
- <https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html>
- <https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app>

## Activation evidence required

1. Design and exact diff reviewed independently; no cleanup call reachable from UI or runner.
2. Exact-commit macOS Swift builds/tests and signing of the nested supervisor; parent entitlements unchanged.
3. Synthetic helper tests cover real execution, zero/partial/unavailable/invalid JSON, forged outside paths, stdout/stderr floods, CPU/time limits, cancel, parent disconnect, child-helper exit and no unrelated PID signaling.
4. Synthetic filesystem tests cover source/scope/session replacement and symlink races, quarantine, wrong hash/architecture, metadata retention, scope/cache overlap, strict anchored session cleanup and untouched original inputs.
5. Official pinned upstream binary tested only on unique temporary fixture directories in macOS CI: expected report arrives, target sentinel content/identity remains unchanged, existing Mole cache sentinel remains unchanged, and no real user directory is scanned.
6. User-visible confirmation, partial/failure/cancel, repeated starts, Demo transitions, navigation and app closure covered. No claim of completed native/manual testing until exact evidence exists.

The ordinary permissions model cannot prevent a malicious same-user process from replacing ancestors or moving foreign content into app-owned storage. Descriptor anchoring, identity checks, private ownership/mode and source freezing reduce accidental/racy path misuse; they do not create adversarial filesystem confinement. Cross-device cleanup is refused.

No release or merge follows from this design alone.
