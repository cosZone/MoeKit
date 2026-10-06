# Docker cleanup / Docker 清理

## User workflow / 使用流程

Tools → Mole → Cleanup → Docker (the combined Cleanup category navigation is
integrated with the other cleanup modules). Opening this view is inert.

1. Choose **Docker Desktop** (`~/.docker/run/docker.sock`) or **Local Docker Engine**
   (`/var/run/docker.sock`), then **Connect and refresh inventory**. The resolved
   socket path, daemon ID, server version, OS and reported rootless state are shown.
   Legitimate Desktop socket symlinks are resolved and their identity is checked.
   This is MoeKit's explicitly selected local endpoint, not the Docker CLI's active
   context. Remote contexts are not contacted. Start Docker yourself if unavailable.
2. Select exact unused image IDs and, optionally, explicitly selected created/exited
   containers. Every container reference protects an image, including stopped
   containers. Compose project/service labels and image dependencies are visible.
   Arbitrary labels, commands, environment variables and credentials are not shown.
3. Build cache has a separate **all unused build cache on this daemon** choice.
   Engine exposes a prune operation rather than an exact-record deletion contract.
   Cache rows are informational; there are no misleading per-cache-record checkboxes.
   The confirmation requires a second acknowledgement for this daemon-wide scope.
4. Review the full image/container IDs, tags and actual daemon identity. Explicitly
   acknowledge permanent removal. The one-use plan expires after 60 seconds.
5. MoeKit refreshes identity and dependencies again, performs fixed Engine API calls,
   then verifies absence using a fresh inventory. Failed, retained, skipped and
   uncertain outcomes are distinguished. No automatic retry follows a partial result.

中文：主动连接本地 Docker → 读取清单 → 选择精确镜像／已停止容器 → 复查 daemon、
完整 ID 与不可恢复影响 → 明确确认 → 实际执行 → 刷新验证。打开页面不会自动读取或清理。
包括已停止容器在内，任何容器引用都会保护镜像。运行中、暂停、重启中、dead 或未知状态
容器不能选择。已停止容器的可写层会永久删除，卷保留。镜像被多个 tag 引用而 Docker
拒绝无 force 删除时，如实显示失败，不升级权限、不自动改用 force 或逐 tag 删除。

构建缓存是单独确认的“整个本地 daemon 的未使用构建缓存”，包含 internal/frontend
缓存，不能假装是精确缓存行删除。该操作可能使后续构建变慢；不会连接其他 builder 或
远端 context。命名卷与匿名卷只读列出并始终保护，不做 volume prune。

## Boundaries / 边界

- No `docker system prune`, volume deletion, network pull, CLI execution, shell,
  executable installation, plugin/config loading, Docker credential file reads,
  socket permission changes, privileged helper or daemon start.
- No container inspect endpoint: container environment/command details are not
  requested. Inventory uses `/system/df` and `/containers/json?all=1`; only a narrow
  typed field set is decoded and only Compose project/service labels are displayed.
- The direct AF_UNIX HTTP client has a fixed request allowlist, 30-second per-request
  deadline, 16 MiB body limit, 16 KiB header limit, strict HTTP framing and cancellable
  nonblocking IO. It supports Linux Engine API 1.44 when the daemon's advertised
  version range includes it. Unsupported APIs fail closed. This is not a public TCP
  or remote Docker client. It reads no CLI context/config files.
- Every request verifies the resolved local socket's device, inode and owner. Regular
  files and world-writable sockets are refused; root/current-user-owned sockets are
  supported. Every inventory checks daemon identity before and after collection.
- Image deletion is by full `sha256:` ID with `force=false&noprune=true`; parent images
  are not pruned. Multi-tag conflicts or newly referenced images are retained on
  Docker refusal. Container deletion is by full ID with `force=false&v=false`.
- Deleting a stopped container does not implicitly select its image afterward.
  The user refreshes/selects again if they want to remove that newly unused image.
- Volumes have no deletion path. Running containers are never stopped. Cache prune
  is an independently disclosed `POST /build/prune?all=true`; Docker protects cache
  currently in use. Newly shared/in-use cache can remain and is reported honestly.
- Size is not a promise. Image unique estimates are `Size - SharedSize` only when
  valid. Shared layers are never naively summed across selections. Engine-reported
  cache reclamation need not immediately shrink Docker Desktop's sparse disk image
  or return the same physical bytes to macOS.
- Cancellation prevents subsequent mutations. A request already accepted by Docker
  can still finish. A fresh bounded read attempts to establish what happened; unknown
  stays unknown. No retry/rollback is fabricated. App update replacement is blocked
  while the operation and its verification are running.
- Endpoint changes, selection changes, Demo transitions, dismissal and used/expired
  confirmations invalidate authority. Demo never starts a daemon connection. No
  receipts claim these permanent Docker deletions can be restored by MoeKit.

中文：没有静默联网拉镜像、提权、自动安装、权限修改或远端操作。取消不会撤销 Docker
已经接收的请求，模糊结果必须重新读取清单后再决定。共享层不叠加成“可回收总量”；
Docker 报告的回收量不等于 macOS 立刻释放的物理空间。整个操作期间阻止应用更新替换。

## Verification / 验证

- `Tests/DockerCleanupTests.swift`: in-memory daemon fixtures cover stopped references,
  active/unknown container states, exact selected deletion, retained neighbors/volumes,
  daemon changes, confirmation replay, cancellation, conflicts, uncertain outcomes,
  whole-cache scope, bounded HTTP, controller dismissal and immediate Demo transitions.
  Native macOS socket tests use only fresh `/tmp/mk-docker-*` fixtures, including a
  Desktop-style symlink. They never contact the user's Docker daemon.
- `Scripts/run-docker-cleanup-fixture.py`: explicit GitHub-hosted-runner-only opt-in,
  exact source SHA, a unique marker-owned `/tmp/moekit-docker-*` daemon, separate data/
  exec roots and Unix socket, empty daemon/client configuration, no host networking
  configuration changes and no package installs. Scratch images use fixture bytes
  and the hosted runner's OS binaries, without registry pulls. The production Swift
  transport/executor removes selected real images and a created container, prunes
  actual unused build cache, and verifies a running container, unselected images and
  a volume remain. Its daemon log and source-bound JSON proof are preserved by CI.
- Run `python3 Scripts/verify-source.py` locally. This is structural verification,
  not Swift compilation or UI acceptance. Existing Native CI builds the SwiftUI app
  and runs macOS tests; the dedicated Docker workflow validates the real Linux API.
- Manual macOS acceptance still needs a user-authorized disposable local daemon:
  Desktop/Engine unavailable state, rootless identity, text selection/VoiceOver,
  repeated clicks, dialog dismissal, endpoint switches, Cancel during a slow daemon,
  and real/Example mode changes. Do not test deletions against personal Docker data.

Official contracts used: [Docker Engine API 1.44](https://docs.docker.com/reference/api/engine/version/v1.44/),
[Docker disk usage](https://docs.docker.com/reference/cli/docker/system/df/),
[Docker pruning](https://docs.docker.com/engine/manage-resources/pruning/).
