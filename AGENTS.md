# MoeKit development conventions

## Product and current milestone

MoeKit is a native macOS home for a personal CLI toolbox. Projects, Tools and Tasks are the primary workspaces; Mole is one built-in module, not the app's whole identity. Prefer SwiftUI and AppKit with SF Symbols for interface icons. Use the approved custom artwork for the app icon.

The first source milestone implements navigation, explicit demo fixtures, bounded read-only project discovery, project-catalog persistence, a compiled-in tool registry, and Mole JSON report import. It additionally supports one reviewed execution adapter: exact pinned official Mole directory analysis after per-run scope/cache-write confirmation. Arbitrary CLI execution and cleanup remain unavailable. Read README.md and Documentation before making changes. Distinguish authored, built, tested and manually verified; never fabricate success or describe example data as a real result.

## Engineering

- Swift 6, macOS 15+, Tuist 4.148.3, SPM dependency management. There are currently no third-party runtime dependencies.
- UI/coordinator state is @MainActor and @Observable. Blocking IO belongs off MainActor. Cancel obsolete work and do not let stale results cross real/demo mode boundaries.
- No shell-string execution, arbitrary CLI commands, project scripts/hooks, automatic CLI installation, privileged helper, or user-target mutation. Only the reviewed pinned Mole analysis adapter may execute; its temporary executable/cache writes and private-session cleanup must be explicit and app-owned.
- Discovery is scoped to a user-selected directory, has explicit budgets, does not follow symlinks, and does not infer Git cleanliness from HEAD. Unreadable and unknown states remain visible.
- Mole cleanup has no selected-path execution contract. Do not connect GUI selections to unbounded clean/purge commands. Old JSON without coverage is unknown, unavailable size is not zero, and overview totals may overlap.
- Test filesystem operations only in unique temporary fixtures. Do not run deletion tests against real projects.
- Original implementation only: do not copy GPL/AGPL application or CLI source. The project license remains undecided.

## Verification and publishing

Use Scripts/verify-source.py for structural checks, then the documented macOS build/test workflow. Python checks are not Swift compilation. Report failing, unrun and passed stages separately. CI may build an ad-hoc preview artifact; public releases and signing use separately reviewed workflows. Never commit credentials, P12 data, passwords, Team IDs, personal signing identities or keychains. No secrets in pull-request jobs; no pull_request_target execution of an untrusted head. A signature is not Apple notarization.
