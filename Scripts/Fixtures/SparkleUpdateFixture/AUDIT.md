# Native Sparkle fixture audit

This validation fixture is separate from MoeKit's production updater. It runs only as a non-root user on GitHub-hosted macOS, at the exact checked-out source SHA, with the pinned Sparkle 2.10.0 package. It uses public RFC8032 test vectors in unique generated synthetic apps; it never uses a production signing key or real-app preference domain.

## Callback meaning

`didExtractUpdate` in pinned Sparkle 2.10.0 reports that installer startup completed. It can occur before archive validation/extraction fails. The fixture records this as `installer_started`; it is neither validation success nor permission to install. `showReadyToInstallAndRelaunch` is the preparation-complete boundary. Rejection cases require exact native signature/unarchiving errors, complete delivered/received bytes where appropriate, no ready/install/relaunch event, and an unchanged original app digest.

Sources: [core driver](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Sparkle/SPUCoreBasedUpdateDriver.m), [UI driver](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Sparkle/SPUUIBasedUpdateDriver.m).

## Genuine cancellation

The cancel case chooses download/install, receives a positive but incomplete native archive payload, invokes Sparkle's actual download-cancellation callback, and records `userDidCancelDownload:`. The loopback server paces only this archive. Success requires incomplete native and server byte counts, no completed archive response, no installer-start callback, and an unchanged old app. Skipping a version is not accepted as cancellation.

## Case isolation and lifetime

The harness pins the private root, owner marker, case directory, installation directory and append-only event inode. It refuses namespace replacement, symlinks, malformed events, excess output and unrelated neighbor changes. It retains all fixture data; it never removes trees or signals app/helper process names, PIDs, groups or descendants.

Before installation, the host pauses at ready-to-install. The read-only native probe must capture stable PID, UID and process-start identities for both the exact root-confined Autoupdate installer and Updater progress agent. Only then does the harness create a marker-bound, exclusive `install-ack`. These identities remain tracked if Sparkle moves the old executable outside its original path during replacement.

Probe paths use POSIX `realpath` and the parent's pinned root device/inode, with a retained root descriptor. Foundation presentation normalization is not an identity check: it may remove `/private` for a filesystem alias. Before any updater launches, the native preflight requires the physical `/private/var` root and its `/var` alias to identify the same empty owned fixture, and requires an intentionally wrong root inode to be specifically refused. The running app must resolve to the exact case's installed app path. Captured helper identities remain live even if replacement removes their former executable path.

The probe checks exact fixture bundle identity, current-user executable metadata confined to the generated root or exact fixture cache, tracked process identities, and all three pinned Mach service names (`-spki`, `-spks`, `-spkp`). Only `BOOTSTRAP_UNKNOWN_SERVICE` means that service is absent in this bootstrap namespace. Status-service absence alone is insufficient: Sparkle invalidates listeners before all cleanup is finished. A stable zombie cannot execute cleanup; the harness separately reaps its direct old-app child. No command-line arguments or process environments are inspected.

Process inventories are read twice and rechecked. A newly born process during enumeration produces an inconclusive snapshot, never idle or permission to install; it can be sampled again only within the current bounded phase. Other identity, access, namespace and probe failures abort. Before the next case, the old child must be reaped and exact app/helper/service/HTTP-response absence must remain observed for at least one second. Unknown settlement aborts the batch.

Sources: [service names](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Autoupdate/SPUMessageTypes.m), [installer lifecycle](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Autoupdate/AppInstaller.m), [old-app replacement](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Autoupdate/SUPlainInstaller.m), [launcher](https://github.com/sparkle-project/Sparkle/blob/2.10.0/InstallerLauncher/SUInstallerLauncher.m), [Apple bootstrap lookup](https://github.com/apple-oss-distributions/launchd/blob/main/liblaunch/bootstrap.h).

## Consolidated outcome collection

All ten independent cases are attempted in one batch when each preceding case has affirmatively settled. Ordinary assertion failures are preserved as failed cases and do not hide later independent results. A missing explicit outcome, namespace uncertainty, unknown lifetime or containment failure stops collection. The overall result passes only if all ten cases explicitly pass. Evidence distinguishes completed, failed and unattempted cases.

The separate `InstallerIdleProbe.swift` changes are console-only diagnostics: at most three holder snapshots inside a cooperative three-second budget, stable PID/UID/start identities, and fixed redacted executable-path categories. Its original observed-use result remains fatal. Later samples never convert that failure to idle evidence or retry the production operation.

## Verification limits

Portable tests exercise guard logic, partial-byte serving, immutable event identity, outcome collection and source invariants. They do not compile Objective-C/Swift or prove native installation. Exact-source macOS CI on arm64 and Intel must establish compilation, installation/relaunch, cancellation and rejection behavior. Synthetic ad-hoc signatures do not establish Developer ID, notarization, production feed delivery, or production key setup. This batch does not change production updater or cleanup eligibility policies.
