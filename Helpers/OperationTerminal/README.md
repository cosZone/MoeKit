# Fixed Homebrew Mole operation terminal

This is an original, single-threaded native C supervisor. Swift launches the
bundled helper with `Process`; Swift never forks. The helper supports precisely
one sequence after the app's fresh one-use confirmation and an actual Return
keypress in the terminal:

1. `/opt/homebrew/bin/brew update`, `/usr/local/bin/brew update`, or the strictly verified Intel canonical `/usr/local/Homebrew/bin/brew update`
2. Only after a normal zero exit and owned-group cleanup:
   the **same fixed path** followed by `upgrade --formula mole`

There is no runtime command, shell-string, interpreter, install, formula-name,
retry, rollback, or arbitrary executable argument. Native kernel shebang
execution is supported. `brew update` updates Homebrew metadata/software and may
replace `brew` itself; it is not a Mole-only metadata operation. Upgrade may
modify Mole and its dependencies. Cancellation cannot undo completed changes.

## Launch ABI, version 1

The helper receives exactly ten positional arguments:

1. Fixed absolute `brew` path above (the canonical path for the supported Intel alias)
2. Current user's HOME
3. `st_dev`, unsigned decimal
4. `st_ino`, unsigned decimal
5. `st_uid`, unsigned decimal
6. Full `st_mode`, unsigned decimal (including file-type bits)
7. `st_size`, unsigned decimal
8. `st_mtime` whole seconds, signed decimal
9. `st_mtime` nanoseconds, unsigned decimal, below 1,000,000,000
10. SHA-256 as exactly 64 lowercase hexadecimal characters

The app supplies its immutable approval snapshot. The helper opens the final
component with `O_NOFOLLOW`, checks regular/executable status, root/current-user
ownership, no group/world-write or set-ID bits, and a nonzero maximum 2 MiB size.
It verifies all snapshot fields plus SHA-256, with descriptor and pathname stat
checks before/after hashing. The descriptor remains open with `FD_CLOEXEC` until
the child's final pathname/descriptor identity check and native `execve`.

HOME is independently checked against `getpwuid(geteuid())->pw_dir`, by directory
identity and current-user ownership. Canonical aliases are allowed; the canonical
HOME becomes both working directory and environment HOME. Set-ID execution is
rejected. No user shell startup files are read by the supervisor.

Before upgrade, `brew` is opened and checked again. A stable new identity and
SHA-256 are required, but equality to the pre-update snapshot is intentionally
not required: the authorized update can replace its own program. An insecure or
symlink replacement blocks upgrade. This revalidation does not independently
attest a newly updated Homebrew version or its network/content trust chain.

### Pathname execution limitation

Homebrew's shebang script relies on its installation path. Executing a copied
script or `/dev/fd/N` would change that contract. Darwin does not provide a
portable descriptor-exec solution preserving Homebrew's native script path. The
helper therefore checks the held descriptor and final fixed pathname immediately
before `execve(path, ...)`. A concurrent same-user/root replacement or in-place
mutation in the final validation-to-exec gap is **not atomically prevented**.
No claim of race-free executable binding is made. Parent-directory symlinks are
not resolved as an additional trust/approval mechanism. The final component
itself must not be a symlink. There is one bounded Intel exception at discovery:
`/usr/local/bin/brew` may be a root/current-user-owned symlink whose raw absolute
or relative target lexically normalizes exactly to `/usr/local/Homebrew/bin/brew`.
The app then displays and launches that canonical path, never the symlink. The
canonical file must be regular and its `realpath` must equal its literal path,
rejecting symlink ancestors/escapes. The fixed alias's type, owner and target are
revalidated before each phase and again in the child immediately before exec.
No other symlink target is accepted. The final-check race caveat still applies.

## stdin: bounded control frames

Each frame is a one-byte ASCII type followed by a four-byte unsigned big-endian
payload length, then that many payload bytes. Streams may split frames anywhere.

- `I`: 2–4,097 payload bytes: one phase tag (`1` for update or `2` for upgrade),
  followed by 1–4,096 raw terminal input bytes; Ctrl-C is an actual byte `0x03`
- `R`: exactly four bytes, unsigned big-endian 16-bit rows followed by columns;
  each must be 1–1,000
- `C`: zero payload bytes; cancel the owned operation

The initial size is 24 rows × 80 columns. A resize received before launch updates
that size. The pending input queue is capped at 64 KiB. Unknown types/phases, wrong
lengths, invalid dimensions, oversized input, and partial-frame EOF are rejected.
Valid input frames whose phase tag is not the active phase are silently discarded.
The app tags input when it is queued, so stale keystrokes still buffered in Swift
cannot become upgrade input even when they arrive after the phase transition.
EOF otherwise cancels the operation. Input received before the child handshake
is discarded. Between phases, queued input and the old PTY are discarded; partial
old input frames cannot inject old keystrokes into upgrade. Resize and cancel
remain live at this boundary. The app must send no passwords or saved credentials.

## stdout: raw PTY bytes

Both command stdout and command stderr are connected to a newly owned PTY for
each phase. Helper stdout carries their raw bytes, including terminal escape
sequences and terminal input echo. These bytes are display data only; they are
never commands or structured status. The UI must not interpret their content as
supervisor records, links to open, or instructions.

The cumulative session limit is 16 MiB, including both phases and echoed input.
Only 64 KiB may queue for delivery. A stdout reader making no progress for five
seconds while data is pending causes owned-group termination; a closed reader
also terminates the operation. The overall session wall limit is 3,600 seconds.
Control input remains monitored during backpressure and final output draining.

## stderr: trusted supervisor records

Only the supervisor writes this pipe. Records are bounded ASCII lines, totaling
less than 1 KiB for the fixed two-phase session:

```
MKOT1 PHASE update
MKOT1 EXIT update 0
MKOT1 PHASE upgrade
MKOT1 EXIT upgrade 0
MKOT1 RESULT 0
```

`PHASE` is emitted after validation, immediately before fork. An attempted launch
can still fail after this record. `EXIT <phase> <code>` is emitted only for
`WIFEXITED`; `SIGNAL <phase> <number>` is emitted only for `WIFSIGNALED`.
Termination records follow owned-group signaling and direct-child reaping.
The final `RESULT` number is also the helper process's exit code:

| Code | Meaning |
| --- | --- |
| 0 | Both phases exited normally with zero |
| 64 | Invalid launch arguments, path, HOME, or snapshot syntax |
| 70 | Supervisor/launch/protocol-delivery internal error |
| 71 | Cumulative PTY output exceeds 16 MiB |
| 72 | Session wall limit |
| 73 | Command nonzero exit or signal termination |
| 74 | Cancellation, parent stdin EOF, or supervisor TERM/INT/HUP |
| 75 | Malformed/oversized control frame or input queue/flood bound |
| 76 | Executable snapshot, digest, or trust validation failed |
| 77 | Stalled/closed stdout delivery |

A missing/truncated final record or disagreement with process status is unknown,
not success. A verification failure with no PHASE record means no command was
started. Any failure after a PHASE record can have partial effects. Dedicated
protocol writes are nonblocking; a missing reader cannot leave the helper hung.

## Process ownership

The child establishes `setsid` and `TIOCSCTTY`, creating its own session/process
group. A two-way handshake prevents it executing any command until the parent
has acknowledged group ownership. This avoids signaling an unrelated old group
that could temporarily have the same numeric ID before the new child creates its
own group. Before acknowledgement only the directly owned child may be killed.

`waitid(..., WNOWAIT)` keeps the direct child unreaped through group cleanup,
reserving its PID/PGID and preventing reuse while it is a cancellation target.
On cancellation, error, timeout, and normal leader exit the supervisor sends
SIGKILL only to that acknowledged group and/or directly owned child, then reaps
the direct child. It never discovers/signals unrelated processes by name or
PID alone. It does not claim control over descendants that deliberately create
another session/process group. Grandchildren are not waitable on Darwin; stopped
reparented zombies may briefly remain for the system reaper.

Inherited descriptors above stderr are closed at startup. SIGCHLD is restored
to default (including clearing inherited automatic-reap behavior), and inherited
signal blocking is cleared. Child core dumps are disabled. The supervisor owns
and cleans up the operation until its child is reaped; the app must await helper
termination rather than treating its cancellation request as completion.

## Exact child environment

```
HOME=<verified canonical current-user home>
TERM=xterm-256color
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
HOMEBREW_NO_AUTO_UPDATE=1
HOMEBREW_NO_INSTALL_CLEANUP=1
HOMEBREW_NO_ANALYTICS=1
LC_ALL=en_US.UTF-8
```

The user HOME and installed Homebrew ecosystem are intentionally real for the
authorized operation. They are not a sandbox or isolated package-manager state.
No inherited `BASH_ENV`, loader overrides, proxy/API-domain overrides, secrets,
or other environment variables are forwarded by this helper.

## Build and synthetic verification

Darwin/macOS uses CommonCrypto and `openpty` from libSystem, with no extra link
libraries:

```
cc -std=c11 -Wall -Wextra -Werror -O2 Helpers/OperationTerminal/main.c -o operation-terminal
```

Linux portable testing uses OpenSSL EVP SHA-256 and libutil:

```
cc -std=c11 -Wall -Wextra -Werror -O2 Helpers/OperationTerminal/main.c -o operation-terminal -lutil -lcrypto
python3 Scripts/test-operation-terminal.py
```

The test script compiles `fixture.c` into a uniquely owned temporary directory,
and separately compiles the supervisor with fixed
`MOEKIT_OPERATION_FIXTURE_BREW`/`MOEKIT_OPERATION_FIXTURE_HOME` string constants.
A separate alias-test binary additionally fixes
`MOEKIT_OPERATION_FIXTURE_ALIAS` to one symlink in that same temporary fixture;
it validates the production alias rules without touching installed Homebrew.
This compile-time-only seam replaces the production allowlist; no runtime
arbitrary-executable ABI is added. Tests use shortened wall/backpressure limits
but retain the actual cumulative 16 MiB output limit. The fixture is not a release
helper or app resource. Never ship a helper built with fixture macros.

No real Homebrew/Mole invocation, installation, update, upgrade, network package
operation, or user-directory mutation is performed by these tests. Portable
success does not establish macOS compilation, signing, UI behavior, or a real
Homebrew upgrade result.
