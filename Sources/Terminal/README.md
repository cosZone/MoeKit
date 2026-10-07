# Controlled Mole upgrade terminal

`MoleUpgradeTerminalStore` is retained by the analysis coordinator, not owned by
one sheet appearance. `prepare(source:currentVersion:recommendedVersion:)` is
called only for an explicit new upgrade-review button action. It performs bounded
static reads, creates an immutable plan and displays both executable/argv pairs.
No helper, Homebrew process, shell, installer or version probe starts while a
review is prepared or a terminal is opened.

Only the local AppKit `keyDown` monitor for a focused TerminalView accepts a
fresh, unmodified Return/keypad Enter. It consumes the plan synchronously before
asynchronous validation. The initial Return and its autorepeats are swallowed
until key-up; they cannot also answer a running command's prompt. Pasted bytes,
`insertText`, terminal `send`, ANSI query replies, and `feed` have no path to this
launch method. Reopening a sheet retains the consumed review. After completion
or cancellation, only a new explicit `prepare` creates a new UUID and snapshot.
There is no automatic retry/resume/rollback.

The known providers are standard Apple Silicon and Intel Homebrew. Normally the
executable is the provider's fixed `bin/brew` regular file. The one supported
Intel alias is `/usr/local/bin/brew` targeting exactly
`../Homebrew/bin/brew` or `/usr/local/Homebrew/bin/brew`; it must have current-user
or root ownership. The canonical `/usr/local/Homebrew/bin/brew` must not contain
another symlink and is the actual displayed/snapshotted executable. Arbitrary
paths, aliases, argument strings, formula names and command editing are absent.

`OperationExecutableVerifier` hashes a bounded descriptor without running it.
The snapshot includes identity, owner/mode, size, modification/change times and
SHA-256. `OperationTerminalSession` freshly resolves/checks the plan after Return
before invoking only the bundled C helper. The C helper independently verifies
and owns the PTY session and process group; see `Helpers/OperationTerminal/README.md`
for the fixed ABI, environment, process ownership and final pathname-exec race
limitation. This verifies the reviewed installed file at launch, not an immutable
sandbox or independent provenance of Homebrew's entire dependency ecosystem.

The transport is nonblocking and off MainActor. Its input queue is bounded to
64 KiB, PTY output to 16 MiB, protocol status to 4 KiB. Each input frame contains
the command phase from the separately validated supervisor status pipe. Old
partially written or queued input cannot become input to the next command.
An async output callback provides bounded delivery rather than unbounded queued
UI tasks. Stop/Close, Demo reset, coordinator release and parent pipe EOF request
owned cleanup; the store remains busy and blocks app updates until the helper
settles. Ctrl-C is an actual PTY input byte, not PID signaling.

SwiftTerm is used only as `TerminalView`, at exactly v1.20.0 commit
`5d14406844143538cd8f8851d2d8a67c1fe443e5`. Its LocalProcess implementation is not
used. Native Swift Package integration must retain its required build-info plugin
and Metal resource. Rendered history is limited to 2,000 lines. A streaming
allowlist retains ordinary ANSI text/color/cursor controls and strips OSC,
DCS/Sixel, APC/kitty and other control strings. Window-resize CSI commands and
unbounded numeric parameters are rejected. Clipboard read is explicitly denied;
clipboard writes, URL activation, title/cwd and iTerm side-effect delegates do
nothing. Links and mouse reporting are disabled. Only explicit user copy/paste
UI actions interact with the clipboard. Supervisor results use a separate pipe,
so terminal output can never forge successful completion.

Native tests are in `OperationTerminalTests.swift` and
`OperationTerminalViewTests.swift`; the latter generates pending/active/success/
failure/cancel TerminalView screenshots in both appearances. Their runner is
synthetic and performs no Homebrew operation. Portable C PTY tests are in
`Scripts/test-operation-terminal.py`. Passing portable checks does not establish
Swift compilation, native rendering, keyboard/VoiceOver acceptance or a real
upgrade result. A successful Homebrew exit still requires a fresh installation
check to establish the installed Mole version and reviewed analyzer eligibility.
