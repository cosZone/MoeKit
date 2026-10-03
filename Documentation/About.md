# About MoeKit

## Native entry points

- **MoeKit → About MoeKit** opens one dedicated SwiftUI `Window`; opening the command again brings that window forward. Escape, Command-W and the standard close control dismiss it. It is not restored or opened automatically on launch.
- **Settings → About** shows the same content alongside the existing General settings. The About view does not change the preview toggle, workspace selection or project data.
- The content uses the application's existing icon, bundle version/build, bundle copyright, native text styles and SF Symbols. Missing version/build fields remain unavailable rather than falling back to a made-up release.

## Public links

- **Feedback** opens <https://github.com/cosZone/MoeKit/issues>.
- **Give a Star** opens <https://github.com/cosZone/MoeKit>. Starring remains an explicit action on GitHub; MoeKit never signs in, stars automatically, reads star status or submits a feedback report.
- Neither URL includes diagnostic data, project paths, app metadata or query parameters. Links use the default browser. No updater, license claim, Discussions link or unpublished documentation domain is advertised.
- English and Simplified Chinese copy is included in the string catalog.

## Design reference

The user requested the placement used by their MoePeek app. The current public source at `f12d42122ae3129177cf7d8ce78ca0a910d419d7` was inspected:

- [SettingsView.swift](https://github.com/cosZone/MoePeek/blob/f12d42122ae3129177cf7d8ce78ca0a910d419d7/Sources/UI/Settings/SettingsView.swift) places About in a Settings tab.
- [AboutSettingsView.swift](https://github.com/cosZone/MoePeek/blob/f12d42122ae3129177cf7d8ce78ca0a910d419d7/Sources/UI/Settings/AboutSettingsView.swift) presents app identity/version above bottom feedback and discussion links. That source does not contain a Star button.

This is an original MoeKit implementation of that placement concept. It does not copy MoePeek's AGPL implementation, updater integration, license statement or destinations. The requested Star link is a MoeKit addition.

## Verification

`Tests/AppInformationTests.swift` covers metadata presence, missing/invalid fields, partial values and exact public link destinations without app or user data in their URLs. The existing Native CI compiles the app and runs all Swift tests on macOS; source checks on Linux are not Swift or UI verification.

The following native acceptance checks are still manual, not claimed as passed by CI:

- [ ] Open About from the app menu with the main window, Settings window and no main window active
- [ ] Open About repeatedly: one dedicated window, brought forward; close with Escape, Command-W and the close control; reopen and relaunch without unwanted restoration
- [ ] Switch General/About repeatedly: preview setting and workspace state unchanged; General form remains scrollable and all existing sections remain reachable
- [ ] English and Simplified Chinese; light/dark mode; increased contrast; no clipped labels, icon, version or copyright
- [ ] Keyboard focus, Tab/Shift-Tab and VoiceOver read Feedback and Give a Star by name
- [ ] Feedback and Give a Star open the exact destinations in the default browser; no automatic GitHub action

SwiftUI lifecycle references: [Window](https://developer.apple.com/documentation/swiftui/window), [restorationBehavior](https://developer.apple.com/documentation/swiftui/scene/restorationbehavior(_:)) and [defaultLaunchBehavior](https://developer.apple.com/documentation/swiftui/scene/defaultlaunchbehavior(_:)).
