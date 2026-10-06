# Signed automatic updates

This document describes the new source integration, not the already-published preview.9. Preview.9 has only a manual GitHub release check. A first updater-enabled build must still be downloaded manually; earlier releases cannot acquire Sparkle without replacement.

## App behavior

- Exactly pinned Sparkle 2.10.0 supplies `SPUStandardUpdaterController`. One app-lifetime controller is shared by the application menu, menu bar icon and Settings. Sparkle owns download, verification, installation and relaunch; MoeKit does not implement an alternate installer.
- Sparkle's standard second-launch permission prompt asks about background update checks. Automatic download/install defaults to off. Settings changes go directly to Sparkle's persisted properties and are never reset on launch. When enabled, automatic installation normally waits for quitting the app. Manual checks use Sparkle's standard progress/cancel/review/install UI.
- Previews opt into the `preview` channel by default; stable releases do not. The user's channel choice persists independently. The default/stable feed channel remains included by Sparkle. Switching channels resets the update cycle; it does not authorize a downgrade.
- Missing/invalid public key, release provenance, semantic build number or security configuration prevents updater construction. Development builds, XCTest, `--demo` and `--disable-updates` processes do not instantiate or start Sparkle. The Settings “Use demo data” switch changes only workspace data; it does not suspend app-wide updating in an already running release. Only a process launched with `--demo` is updater-isolated. A manual GitHub release view remains available when the updater cannot start. A signed-feed or archive-validation failure never falls back to that manual view automatically or to an unsigned installer.
- App replacements cannot terminate MoeKit while an original cleanup/Trash/restore/Git mutation/process-termination/Mole analysis adapter is busy. Native termination refuses with a visible explanation. Read-only scans, imported reports and task records are session-only and may end on restart; users should finish their work before installing.
- The app's project catalog, pins, preferences and private recovery receipts live outside the app bundle. Updating replaces `MoeKit.app`, not Application Support or user projects. No updater failure triggers cleanup, reset of preferences, quarantine removal, Gatekeeper override or privileged custom helper.

## Verification boundary

The reviewed feed is `https://raw.githubusercontent.com/cosZone/MoeKit/updates/appcast.xml` on a dedicated history-preserving branch. Appcast updates are published only after immutable release assets are verified. Public source hosting does not expose the signing key.

Release bundles set:

- `SUPublicEDKey`: the explicitly supplied MoeKit public Ed25519 key
- `SURequireSignedFeed = true`
- `SUVerifyUpdateBeforeExtraction = true`
- `SUSignedFeedFailureExpirationInterval = 0`, preventing the default timed unsigned-feed fallback
- `SUEnableSystemProfiling = false` and `SUEnableJavaScript = false`

The feed URL is fixed by the updater delegate, so a stale Sparkle feed URL preference cannot silently redirect it. Sparkle may send the app version and the server receives the client's IP address; project/task contents and system-profile fields are not sent. Signed archives are verified before extraction and normal Sparkle installation checks still apply.

`Configurations/Sparkle.json` pins the exact version, revision and binary archive SHA-256, feed URL and public key. `Package.resolved` locks the upstream manifest revision. The original Sparkle/dependency notices are included in `Resources/ThirdPartyNotices/Sparkle-LICENSE.txt`. There is no MoePeek source reuse.

## Version order

`CFBundleShortVersionString` remains the display core version. `MoeKitPreviewVersion` / `MoeKitReleaseVersion` hold the complete release version. `CFBundleVersion` is an independent, deterministic numeric mapping: `(major × 100 + minor + 1).patch.slot`; slots 1–98 represent preview numbers, and 99 is stable. Major is limited to 0–98 and minor/patch to 0–99. Out-of-range versions fail release preparation rather than truncate or collide.

Examples: preview.9 → `2.0.9`, preview.10 → `2.0.10`, stable 0.1.0 → `2.0.99`, next patch preview.1 → `2.1.1`. Separate workflow run counters are not compared. Earlier non-updater release build counters cannot participate because those applications have no automatic installer.

## Production setup and test status

The dedicated MoeKit public key supplied by the maintainer is pinned in `Configurations/Sparkle.json`. Production signing configuration remains a separate human-controlled step; no private key belongs in source, chat, PR output or diagnostics. The release workflow must compare its public-key input with this reviewed pin and verify signatures against it; missing or mismatched signing prerequisites must fail closed. Pinning the public key does not publish an updater-enabled build or an appcast. See the signed preview release instructions for signing and publication.

Source checks and mocks are not proof of a real installation. Before activation, exact-head macOS CI must compile/link the app, verify the universal nested-code layout, exercise signed synthetic feed/archive validation and demonstrate a fixture-only update and relaunch, including tampering/cancellation/failure refusals. Developer ID/notarization-specific behavior still needs a corresponding release path and cannot be proved by ad-hoc fixtures.

The current distribution remains Apple Development signed and not notarized. Sparkle does not make that build Developer ID signed, notarized or automatically trusted by Gatekeeper. First installation and platform trust restrictions still apply. Never work around them by disabling macOS security.

## Primary references

- https://sparkle-project.org/documentation/
- https://sparkle-project.org/documentation/programmatic-setup/
- https://sparkle-project.org/documentation/customization/
- https://sparkle-project.org/documentation/publishing/
- https://sparkle-project.org/documentation/sandboxing/
- https://github.com/sparkle-project/Sparkle/tree/2.10.0
