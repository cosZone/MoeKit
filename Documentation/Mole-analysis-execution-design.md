# Mole analysis: verified-artifact execution design

This document describes the expanded analysis, compatibility and controlled upgrade design. Each change requires fresh whole-feature review and exact-head native validation before merge/release. The original fixed V1.57.0 analysis path shipped in [preview.6](https://github.com/cosZone/MoeKit/releases/tag/v0.1.0-preview.6); its historical evidence does not validate later implementation changes.

## Deliberate boundary

Analysis means one ordinary directory, a verified direct analyzer, fixed arguments, separate per-run confirmation and an owned bounded lifecycle. It is not `mo`, a shell command, overview mode, arbitrary CLI execution or a cleanup command. Report import, metadata-only tool preparation, online provenance verification and Homebrew upgrade are separate operations. See [compatibility and upgrade](Mole-compatibility-and-upgrade.md) and the [beginner guide](Mole-beginner-setup.md).

The analyzer has ordinary user permissions. This is **not an OS sandbox**, and it does not promise that every incidental metadata read stays below the selected directory. No Mole GPL application/CLI source is copied into MoeKit, and no Mole executable is bundled with the app.

The reviewed catalog contains original official V1.57.0 and V1.58.0 binaries for arm64 and x86_64, plus one exact Homebrew ARM64 1.58.0 binary. Catalog membership means a specific architecture, size and SHA-256 combination. It is not proof of a successful test of the current app. The artifact table and source references are in the compatibility document.

An additional current Homebrew/core major-1 build at or above 1.56.1 can become eligible only through opt-in full-bottle/member verification. Its version remains untested with MoeKit and requires a separate acknowledgement for every analysis. Provenance verifies origin and installed bytes; it does not establish the behavior of an unreviewed build. The ordinary-permissions model cannot enforce the reviewed code's read-only intent on a different future executable. Unsupported major versions, unknown builds and source builds without exact accepted-byte evidence fail closed.

## Discovery, provenance and preparation

- Opening the analysis window triggers only bounded read-only checks of fixed installation locations. Existing managed installations take priority over parallel standalone downloads. Discovery does not search PATH, walk directories, run a wrapper/version/help probe, make network requests or create an analyzer process.
- Version declarations come from bounded static package metadata or the fixed official wrapper's literal version assignment. They are display hints, not executable identity. Old Homebrew 1.50.0 is detected as installed but lacks the live report coverage contract introduced in 1.56.1.
- Descriptor-based reads check regular-file type, owner, permissions, identity, size, SHA-256 and quarantine. Final symlinks and unsafe/changed files are rejected. Homebrew ancestor aliases must resolve into the fixed Cellar layout. No quarantine removal, re-signing or Gatekeeper override exists.
- Online verification is a separate opt-in request to fixed public Homebrew services. It accepts only current core metadata matching the observed keg revision, validates the complete bottle SHA-256 and complete archive, and compares one exact regular analyzer member with a fresh installed observation. Nothing is extracted or executed. Proof is memory-only and expires after one hour; recheck, replacement or mode changes invalidate the selected context.
- Preparation requires an eligible artifact and chosen directory, binds both identities and creates an immutable review. Analysis confirmation expires after five minutes. Execution repeats identity, artifact eligibility, digest, quarantine and scope checks. Selection and preparation alone do not run anything.

## Fixed invocation and side effects

With explicit analysis confirmation, verified executable bytes and security xattrs are copied into a fresh private session and verified again before execution. The embedded signature is unchanged. The confirmation discloses the temporary executable, private cache/temp writes and cleanup; it must not imply that the installed path is executed in place.

Fixed argv is `["--json", absoluteSelectedDirectory]`. No overview, interactive mode, command string, custom options, inherited `MOLE_*`, inherited `DYLD_*`, user PATH, shell or user configuration is accepted. The environment starts empty and supplies a private HOME/TMPDIR, `LC_ALL=C`, `PATH=/usr/bin:/bin` and bounded Go runtime settings. The reviewed ordinary JSON path reaches macOS-owned `du` and `mdfind` through that fixed PATH. Existing `~/.cache/mole` is neither read nor intentionally modified by this design; cache expiry/pruning stays within the private HOME.

A private HOME changes Mole's special home exclusions. Output describes this invocation's filtered scope, not necessarily a terminal invocation with the real HOME. The intended invariant is no selected-content mutation or deletion. Because execution is unsandboxed, a provenance-verified but unreviewed future build does not gain a stronger confinement guarantee.

Root-directory/overview requests, overlap with session storage, stale selections, unsupported artifacts and invalid paths are rejected. Cancel or dismissal before confirmation creates no analyzer process.

## Report semantics and downstream authority

Successful process exit alone is insufficient. Bounded stdout must decode as non-overview JSON, match the exact selected root, provide known coverage, and contain canonical direct-child entry paths and descendant large-file paths. Duplicates, scope escapes, invalid paths and changed/symlink result identities cannot become a successful live report. Missing coverage remains unknown for imports; it is rejected for live analysis. Partial/unavailable measurements remain visibly partial/unavailable, never zero or complete.

A report is a non-atomic, filtered observation, not physical disk use or reclaimable space. A result from an acknowledged untested build is view-only: `MoleAnalysisStore` does not issue its live-result UUID and cannot authorize a downstream selected-entry operation. Importing another report, changing selection or rechecking revokes earlier live-result authority, even for identical paths. Reviewed-catalog output does not itself approve any mutation; an independently supported native adapter still needs its own fresh checks and confirmation.

## Owned analyzer lifecycle and cleanup

The original bundled supervisor owns one analyzer child and dedicated process group, retaining the child PID until group termination is requested so reuse cannot redirect cancellation. It never finds or signals arbitrary processes by name. Cancellation, parent pipe closure, time/CPU/output limits and abnormal exit are terminal and cannot publish success. The supervisor reaps its direct child and requests termination of remaining owned group members; it cannot `waitpid` grandchildren or claim control over a descendant that deliberately leaves its group.

Stdin is closed for analysis. Work runs off MainActor. Cancellation, closing the window and Demo/selection generations invalidate late results, while task ownership remains until cleanup truly settles. Filesystem waits can outlast a cooperative cancellation request; fixed read budgets are not a promised hard timeout for every filesystem syscall.

Only app-created, descriptor-anchored session files may be removed. Cleanup checks identity, refuses links/cross-device changes and retains uncertainty. No broad path-recursive removal, real-user cache pruning or selected-content deletion is performed by MoeKit's analyzer adapter. Same-user/root adversarial changes are outside its confinement guarantee.

## Separate upgrade terminal

Homebrew upgrade is intentionally a different, mutating adapter with real HOME and installed package-manager state. It shows the exact fixed executable plus `update`, followed by the same executable plus `upgrade --formula mole`. Only a fresh focused Return/keypad Enter consumes the review and starts the owned PTY supervisor. Opening, pasting, programmatic terminal input and repeated Return events cannot authorize launch. No shell-string execution, sudo, automatic retry, resume, rollback or downgrade is available.

`brew update` may replace Homebrew itself; a stable and safe fresh executable is revalidated before the upgrade phase. This does not independently attest all of Homebrew's dependencies or eliminate the documented final pathname-validation-to-exec race. Cancellation cannot undo already completed package changes. Reliable helper completion is followed by installation recheck; it is not proof of a compatible analyzer. Full details are in [Sources/Terminal/README.md](../Sources/Terminal/README.md) and [Helpers/OperationTerminal/README.md](../Helpers/OperationTerminal/README.md).

## Why App Sandbox is not claimed

User-selected file access does not establish permission to launch an external executable with dynamic PowerBox rights, and the unmodified Go analyzer does not consume Cocoa bookmarks. A speculative XPC wrapper is not confinement evidence. MoeKit does not use private sandbox APIs, deprecated `sandbox-exec`, entitlement expansion or third-party executable re-signing.

- [Apple: accessing files from App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Apple: App Sandbox entitlements](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html)
- [Apple: embedding a helper tool](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)

## Activation evidence still required

1. Independent review of the complete feature diff, including catalog/provenance policy, view-only authority, command gating, native helper, build resources and signing allowlists.
2. Exact-head Debug/Release macOS builds and tests, both architectures, nested-helper signing/archive checks and unchanged app entitlements. Python checks and Linux C fixtures cannot replace these.
3. Synthetic analyzer fixtures covering valid/partial/unavailable/unknown/forged reports, source/scope replacement, links/quarantine, output/CPU/time limits, cancellation, disconnect and owned cleanup with untouched input/cache sentinels.
4. Exact official 1.57/1.58 artifacts and the pinned ARM64 Homebrew 1.58 artifact executed only on unique private macOS CI fixtures, never real user directories. Merely downloading these fixtures is not execution-test evidence.
5. Online verifier fixtures covering metadata/revision/source conflicts, full bottle and gzip/tar validation, malformed/duplicate/link members, limits/cancel/redirects, changed local bytes, expired proof and untested acknowledgement/authority.
6. Terminal fixtures covering genuine focused Enter and negative launch paths, Return repeat consumption, phase-tagged input, resize/copy/paste/Ctrl-C, output filters, status spoofing, cancel/close/Demo/reopen, snapshot changes, alias checks and reliable versus uncertain settlement.
7. Native rendering and keyboard/VoiceOver review in English and Simplified Chinese, both appearances and small/large windows. Synthetic render existence alone is not manual interaction acceptance.

This design alone does not establish release readiness or an actual user upgrade result.
