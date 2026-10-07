# Mole compatibility and controlled upgrade

## Validation and evidence

The expanded compatibility and terminal feature requires whole-feature review and exact-head native validation before merge/release. Test evidence must identify its exact commit, architecture, workflow and scope. Source inspection and fixture preparation alone do not establish native compilation, interaction acceptance or an actual Homebrew upgrade result.

The planned `latestTestedVersion = "1.58.0"` and corresponding UI recommendation identify the reviewed fixture/catalog baseline. That identifier alone is not test evidence. Historical preview.6 execution results do not cover later implementation changes.

## Three independent questions

| Question | Evidence | What it cannot establish |
| --- | --- | --- |
| What version appears installed? | Bounded static Cellar/receipt or official-wrapper metadata, with conflicts visible | That the file is official, executable, compatible or tested |
| Where did these analyzer bytes come from? | Exact catalog architecture/size/SHA-256, or opt-in current-core full-bottle/member verification followed by fresh local comparison | Behavioral review or a successful native MoeKit run |
| Has this exact adapter/artifact combination been tested? | Exact-head native fixture/build results and separately recorded interaction review | General correctness of another artifact, source build or future major version |

Discovery runs no `mo --version`, `brew --version`, wrapper, shell, installer or analyzer. Metadata and a directory name never grant execution permission. Reuse a verified existing installation; do not silently replace it or make a parallel older copy the default repair.

## Version policy

- Homebrew Mole 1.50.0 is an existing installation, not “not installed.” It predates the `scan_status` coverage contract introduced in [Mole V1.56.1](https://github.com/tw93/Mole/releases/tag/V1.56.1). Live analysis requires known coverage so an unreadable result cannot masquerade as a measured zero. Existing older reports can still be imported with unknown coverage.
- Official 1.57.0/1.58.0 for both app architectures and one ARM64 Homebrew 1.58.0 artifact are in the exact reviewed catalog below. Any matching installed location may supply those accepted bytes, subject to file/path/security checks.
- A major-1 current Homebrew/core build at or above 1.56.1 that is outside the catalog can be eligible only after explicit online verification and an additional untested-build acknowledgement for each analysis. Acknowledgement is bound to that review, never a standing preference.
- An untested result is view-only. It does not receive the live-result UUID used by downstream selected-entry adapters. Valid JSON and matching paths cannot promote it to mutation authority.
- A newer installed version is retained. The app never automatically downgrades it. Other major versions, unknown versions, custom taps and source/modified builds without accepted-byte evidence do not get a generic execution exception. The current-core verifier and upgrade provider are unavailable for custom taps.
- Upgrading and analysis are separate approvals. Homebrew installs its current formula; the displayed recommendation does not pin what `brew upgrade` will install. Installation must be rechecked afterward.

## Reviewed artifact catalog

The authoritative constants are in `Sources/Mole/MoleAnalysisModels.swift`; CI download pins are in `Scripts/prepare-mole-ci-fixture.py`. Size is the direct executable size, not the archive size. The app's architecture controls compatibility, including x86_64 when running the Intel app under Rosetta.

| Origin/version | Architecture | Executable bytes | SHA-256 |
| --- | --- | ---: | --- |
| Official V1.57.0 | arm64 | 3827474 | `62c6b5076349081a34e60256a1471979f600d74d8f4990745a37d30d6faa00e1` |
| Official V1.57.0 | x86_64 | 4022992 | `cff7d9da8bd18cb3364d566186944b5b14b01e21e5bb4a3d61579f553ea39ad7` |
| Official V1.58.0 | arm64 | 3860946 | `e7e6fd63dcbc7db90df1b63f2b2db3357e82ce919cf09df5b0ca645bdb10d180` |
| Official V1.58.0 | x86_64 | 4056192 | `cf0830df63162dc34e120c19a409c130d6f468ed2d6039f9872e63e8a88adbc9` |
| Homebrew/core 1.58.0 | arm64 | 4348258 | `d32d92f4c32d8079d464c496312fa616a9af6580457d40ffe7bfd28213f93866` |

Primary references: [official V1.57.0 release](https://github.com/tw93/Mole/releases/tag/V1.57.0), [official V1.58.0 release](https://github.com/tw93/Mole/releases/tag/V1.58.0), [V1.57.0 source commit](https://github.com/tw93/Mole/tree/6bca4812acd6a3d54ffe97291734c3556a174057), and [V1.58.0 source commit](https://github.com/tw93/Mole/tree/8710fdad68289ee666988a4a46b5a86390c437fc). The official V1.58.0 release metadata records the two size/hash pairs above. Reading release metadata is not downloading or executing the artifacts.

The pinned ARM64 Homebrew fixture is the [content-addressed official bottle](https://ghcr.io/v2/homebrew/core/mole/blobs/sha256:04d1d9a3f78524fe224fde11cb98eae036e97e4f3d425ae53119f7078cb66836), 4090875 bytes, SHA-256 `04d1d9a3f78524fe224fde11cb98eae036e97e4f3d425ae53119f7078cb66836`. Its target is `mole/1.58.0/libexec/bin/analyze-go`. These pins are shared by the catalog and fixture preparer; changes require the exact-head native fixture gate. A Homebrew build generally differs from the upstream release binary even at the same version, so a version-only comparison is insufficient.

## Discovery and static observations

`MoleInstallationDiscovery` has a maximum of 12 fixed candidate locations; the standard set currently has 11:

- Both standard prefixes: `/opt/homebrew/opt/mole/libexec/bin/analyze-go` and `/usr/local/opt/mole/libexec/bin/analyze-go`, constrained to the corresponding `Cellar/mole/<version>/libexec/bin/analyze-go` layout
- Official default: `~/.config/mole/bin/analyze-go`, with a bounded literal version read from the fixed `/usr/local/bin/mole` wrapper
- Standalone recommended/legacy locations: `~/MoeKit-Mole-V1.58.0-<app-architecture>/analyze-go` and `~/MoeKit-Mole-V1.57.0-<app-architecture>/analyze-go`
- Presence-only wrappers: `/opt/homebrew/bin/{mo,mole}`, `/usr/local/bin/{mo,mole}` and `~/.local/bin/{mo,mole}`

It does not walk PATH or read arbitrary scripts. The one official-wrapper metadata read is bounded text inspection, never execution. Homebrew receipt reads are at most 64 KiB. Analyzer observation is at most 8 MiB and requires regular/executable type, current-user/root owner, safe permissions, stable identity/timestamps and no quarantine. Invalid metadata, wrong architecture, unsafe files, missing analyzers, custom taps and conflicts remain distinct. No result claims a complete inventory of the Mac.

Existing managed installations take priority over parallel standalone fallback files. This deliberately keeps an incompatible existing Homebrew version visible so the user can upgrade the same source. Advanced manual selection remains possible; selection alone does not verify or authorize execution.

## Opt-in current Homebrew/core verification

The explicit “Verify official Homebrew build” action performs the following bounded operation:

1. Read current public [Mole formula JSON](https://formulae.brew.sh/api/formula/mole.json). Require the `mole` formula from `homebrew/core`, a stable bottled release and the fixed GHCR root. Stable version plus Homebrew revision must exactly match the observed keg version.
2. Select supported macOS bottle tags for the app architecture. Check all selected bottle declarations before downloading. Linux and unknown platform tags cannot substitute for macOS architecture evidence.
3. Download only content-addressed official bottles. If GHCR requests it, obtain an anonymous pull token for the fixed `homebrew/core/mole` repository. Do not use user credentials. Do not forward that token on the allowed CDN redirect.
4. Hash the complete compressed bottle against the published SHA-256. Inspect the whole bounded gzip/ustar stream, including framing, integrity/footer, all members and end-of-archive structure. Require one regular executable member at `mole/<exact-keg-version>/libexec/bin/analyze-go`; reject duplicate/unsafe paths, target links, ambiguous extensions and malformed/trailing data. No archive member is extracted, launched or installed.
5. Compare the member's complete size and SHA-256 with the observed installed file. Re-discover and require the same selected path, file observation, keg revision and core source before accepting the result. A stale completion cannot replace a newer selection or cross a Demo transition.

Limits: 1 MiB metadata, at most eight architecture-matching bottle declarations, 32 MiB per compressed bottle, 64 MiB expanded bytes, 2048 archive members, 8 MiB analyzer and a 120-second overall cooperative deadline. Cancellation and deadline checks apply during transfer/parsing. This does not promise to interrupt every filesystem syscall instantly.

Only fixed public formula/token/bottle endpoints and narrowly allowed HTTPS CDN redirects are used. Local paths, receipts, hashes and sizes are compared locally and never uploaded. Network libraries use ephemeral state; accepted proof is in memory, expires after one hour and does not become a persistent allowlist. Any unavailable/malformed/mismatched result stays unverified. A failed bottle checksum is not proof that the user's local file is modified.

## Controlled Homebrew upgrade

A user must explicitly request a new upgrade review. Preparation performs bounded static executable/HOME checks and displays both full commands. It does not start a helper or Homebrew. The supported plans are:

```text
/opt/homebrew/bin/brew update
/opt/homebrew/bin/brew upgrade --formula mole
```

or the same arguments at `/usr/local/bin/brew`. The one supported Intel alias may point exactly to `/usr/local/Homebrew/bin/brew`; the canonical regular path is displayed and snapshotted instead. No other provider, command, formula name, path or argument editor is accepted. There is no `install`, `sudo` or downgrade command.

Only an unmodified genuine Return/keypad Enter handled by the focused AppKit TerminalView's local keyDown monitor launches. It consumes the plan synchronously before asynchronous validation. The launching key and repeats are swallowed until key-up. Opening/reopening the sheet, paste/newlines, `insertText`, TerminalView `send`/`feed`, ANSI query replies and old keyboard input cannot launch or reuse it. A later retry requires a new explicit review; no automatic retry/resume/rollback exists.

The app checks a fresh descriptor snapshot; the original bundled C helper independently checks identity, size, safe owner/mode, timestamp and SHA-256 before owning the PTY/session/process group. The first command must exit normally with zero and its owned group must settle before `upgrade --formula mole` begins. Homebrew can replace itself during `update`, so phase two revalidates a stable safe new executable instead of requiring the old digest. That does not independently attest Homebrew's full dependency ecosystem.

The real HOME and fixed package-manager PATH are intentional. `HOMEBREW_NO_AUTO_UPDATE=1`, `HOMEBREW_NO_INSTALL_CLEANUP=1` and `HOMEBREW_NO_ANALYTICS=1` disable incidental modes; the explicitly displayed `brew update` still runs. No user shell startup files or inherited loader/proxy/API overrides/secrets are supplied. `brew update` can change Homebrew metadata and software, and upgrade can modify Mole/dependencies. Cancellation cannot undo those effects. No saved credentials or passwords are supplied by the app.

## Terminal rendering, lifecycle and limits

SwiftTerm is pinned to [v1.20.0 commit 5d14406844143538cd8f8851d2d8a67c1fe443e5](https://github.com/migueldeicaza/SwiftTerm/tree/5d14406844143538cd8f8851d2d8a67c1fe443e5), used only as TerminalView. Its LocalProcess is not used. Keep the required Swift Package build-info plugin, Metal resource and [MIT notice](../Resources/ThirdPartyNotices/SwiftTerm-LICENSE.txt).

The original helper owns the process. Swift performs no fork. The output filter allows bounded ordinary ANSI text/color/cursor sequences and rejects OSC/DCS/APC and side-effect controls. Clipboard reads/writes through escape sequences, automatic links, title/cwd and iTerm side effects are disabled; explicit user copy/paste remains available. Rendered scrollback is limited to 2000 lines. A separate trusted supervisor pipe, not displayed PTY text, determines status.

Input is queued nonblockingly with a 64 KiB bound and phase tags; queued or partially written update input cannot become upgrade input. Each phase gets a fresh PTY. Total output is capped at 16 MiB, the session at 3600 seconds, and stalled output delivery at five seconds. Stop/Close, Demo reset, coordinator release and parent EOF request owned cleanup. Ctrl-C is actual PTY input, not arbitrary PID signaling. The task remains busy and blocks app replacement until helper settlement.

The helper preserves direct-child identity through group cleanup and never signals unrelated PIDs by name. It cannot guarantee control of descendants deliberately leaving its group. It uses pathname execution to preserve Homebrew script semantics: descriptor/path checks reduce but do not atomically close a same-user/root change between final check and `execve`. This is not a sandbox or a race-free executable-binding claim. See the [helper protocol and caveats](../Helpers/OperationTerminal/README.md).

Missing/truncated/disagreeing final protocol status is unknown, never success. Failure after launch may have partial effects. A normal zero exit means the two commands succeeded according to their exit status; it does not establish installed version or analyzer compatibility. The coordinator rechecks after settlement. Cancellation, partial effects and uncertainty must remain visible, with no automatic retry, deletion or rollback.

## Native validation gate

Before merge/release, review the whole feature and run exact-head native Debug/Release, architecture, owned analyzer/bottle/PTY fixtures, negative launch/cancel/stale-state tests, archive/signing checks and UI renders. Record native keyboard/VoiceOver acceptance separately. Portable structure or C fixture checks have narrower scope. Fixtures must use uniquely owned temporary roots and synthetic Homebrew programs; never run update/upgrade or scan a real user installation for tests. The [execution design](Mole-analysis-execution-design.md#activation-evidence-still-required) lists the required coverage.

Record passed, failed and unrun stages separately in the pull request and release evidence. Do not advance the planned tested baseline from provenance verification, source review or downloaded fixtures alone. A successful command fixture does not claim a user installation was upgraded.
