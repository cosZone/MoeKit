# Native Trash management / 原生废纸篓管理

## 中文：如何使用

Tools → Mole → Cleanup → Trash。此功能使用独立的原生适配器，不运行 Mole `clean` / `purge`，也不运行 Finder AppleScript、shell、提权助手或广域删除命令。

1. **扫描个人废纸篓**：只读扫描当前用户的 `~/.Trash`。启动应用、切换分类、选择项目或取消确认均不会自动扫描或创建操作记录。
2. **查看与选择**：显示精确名称、逻辑大小与文件最后修改日期。原始位置和进入废纸篓的日期明确标为不可用；不解析 Finder 的私有元数据，不将修改时间冒充删除时间。链接作为叶节点，不跟随目标。可筛选名称、按大小排列、选择支持的项目。
3. **删除所选项目**：点击“复查所选项目的删除…”，查看所有选择及完整后代路径清单，确认已停止使用这些文件的应用，并明确接受不可恢复的永久删除，再执行。
4. **清空本次快照**：点击“复查清空已扫描废纸篓…”。必须全部项目可完整验证，另行复查整个快照，并准确输入 `EMPTY`。筛选不改变清空范围。确认前出现新项目会使清空计划失效；执行开始后新到达的项目也不会加入确认或被删除。
5. **结果与中断**：按项展示已删除、保留或未尝试结果。取消尽量在下一次修改前停止，已经完成的删除不能撤销。操作中断后可主动读取记录并在 Finder 中打开操作文件夹；不自动重试或恢复。

移入废纸篓与这里的永久删除是不同操作。删除释放的物理空间不保证等于逻辑大小：已打开文件、硬链接、APFS 快照和克隆可能继续占用空间。

## 支持范围与明确限制

- 仅当前非 root 用户自己的个人废纸篓，本地内置可写 APFS。外置卷、其他用户的 `.Trashes/<uid>`、网络/云卷及任意用户选择的目录未实现，不提供无效的清空按钮
- 容器路径必须不含符号链接；废纸篓根必须为当前用户所有、0700、无 ACL 的私有目录。生产路径的祖先只允许 root 或当前用户所有，不能允许组/其他用户写入，拒绝变更授权 ACL；不会修改权限
- 支持常规文件、目录（含非空树）与符号链接；同一树内硬链接安全按确认条目计数。删除一个硬链接不影响其他链接中的字节。跨顶层项目的同 inode 链接可能使后续项目重新验证失败，失败项会保留并要求重新扫描
- 拒绝其他 UID、特殊设备/管道/socket、不支持标志、云属性和修改授权 ACL。凭据、保险库、MoeKit 恢复名字以及含 Git/版本控制元数据的目录受保护；在 Finder 中手动管理这些项目。不是通用项目删除器
- 每次最多 256 个顶层项目、25,000 个清单条目、64 层深度、每棵树 96 个目录描述符，初始扫描 45 秒预算。超限内容不会被当成空或零大小；不能完整验证时不能清空快照。历史最多保留 4,096 个独立操作目录，不自动删除；达到上限时停止并要求手动检查历史存储
- 每次确认 120 秒有效、单次消费。选择变化、取消、模式切换、离开视图及重扫会撤销旧计划。繁忙状态会阻止 Sparkle 为安装更新终止应用
- 不能证明所有程序均未使用文件，也不防御恶意同 UID 程序侵入私有存储。请先停止使用项目的应用；身份校验、独占移动和私有捕获缩小竞态影响，不宣称提供内核级全局锁

## 原生删除与恢复证据

复用 `InstallerDirectoryAnchor`、`InstallerFileAccess`、`CleanupFiles` 和唯一的 `CleanupPermanentRemoval` 不可逆接收点。没有路径递归删除调用。全部选择在写记录前重验；每项先移入新建的 0700 私有操作目录，核对完整清单，持久化删除意图。每个待删除叶或空目录再次独占捕获到私有槽、复核 inode/卷/模式/所有者/时间/大小/链接信息及链接目标，再调用 `unlinkat`。目录根与祖先命名空间在每个捕获检查点复核。替换或不确定对象保留，不回滚覆盖、不自动重试。

记录位于 `~/Library/Application Support/MoeKit/TrashRemovalRecords/<UUID>/`，包含原废纸篓路径、身份和已确认清单，写入后同步。中断可能留下 `payload`、`delete-entry-*` 和 JSON 记录；请检查整个目录，不能只看 `payload`。记录是只读证据，不能直接授权重新删除。界面显示最近 128 条摘要，更早记录继续保留。此功能不提供通用“放回原处”；MoeKit 缓存和下载映像的既有恢复凭据仍属于原来的工作流。已在本界面永久删除的对象无法用旧凭据恢复，旧凭据的实时身份复查会拒绝。

## English: scope and safety contract

Use Tools → Mole → Cleanup → Trash. Explicitly scan the current user's home Trash, select eligible items, review every exact path and descendant, attest that workloads are stopped, and confirm irreversible deletion. The separate “clear scanned Trash” action requires a complete eligible snapshot and the literal `EMPTY`. Filtering never changes the approved scope. New arrivals are never silently added; a membership change before a clear begins invalidates it.

Only the current non-root user's fixed home `.Trash`, on local internal writable APFS, is supported. External-volume and other users' Trash are not implemented. No broad Mole operation, shell, AppleScript, privileged helper, permission repair, or automatic startup scan is involved. Unknown original paths and deletion dates stay unavailable; Last modified means modification date. File sizes are logical bytes, not a promise of physically reclaimed space.

Read-only inventory, immutable one-use 120-second plans, fresh full-batch revalidation, descriptor-relative no-follow access, ACL/owner/flag checks, durable capture intent, same-volume exclusive moves, and the existing private-slot irreversible sink form the deletion path. Files, symlink roots and nonempty directories are supported. Symlinks remain leaves. Credential/vault/control names, Git metadata, foreign UID entries, special files, cloud metadata, unsafe permissions and unsupported filesystems are refused visibly. Ordinary concurrent changes fail closed. This does not prove global non-use or resist a malicious same-UID writer in private storage.

Cancellation and partial failures preserve actual per-item outcomes and retained data. Every later item is reported as unattempted after a stop. A fresh scan cannot retry a private retained slot; there is no automatic replay, rollback or overwrite. The history viewer is read-only, showing the latest 128 record summaries. Data and records persist in the private operation directory for manual Finder inspection. A bounded 4,096-directory lifetime history stops safely at capacity; records are never silently swept. App-update termination remains blocked while the adapter is active.

The supported budgets are 256 top-level items, 25,000 manifest entries, 64 path levels, 96 held directory descriptors per target and a 45-second initial scan budget. When exceeded, no unknown contents are authorized. Open files, hard links, clones and APFS snapshots can reduce or delay physical space reclaimed.

## Verification status

`TrashExecutorTests` uses only uniquely created owned temporary fixture trees, never the real user's Trash. Cases cover files, nonempty trees, symlinks, internal/external hard links, exact snapshot membership, later arrivals, changed descendants, replacement roots/leaves, ACLs, unsupported file types, no-overwrite behavior, cancellation, retry rejection, partial batches and incomplete records. `TrashStoreTests` covers inert construction, stale generations, one-use and typed confirmation, expiry, cancellation, Demo isolation and update-installation blocking. `TrashViewTests` renders synthetic selected/clear confirmation views in English and Simplified Chinese, light/dark appearance; rendering does not claim keyboard or VoiceOver acceptance.

Run `python3 Scripts/verify-source.py`, then the documented macOS Debug and optimized Release tests. Native CI includes the new tests in its Release address-sanitizer selection and Chinese view run. Linux structural checks are not Swift compilation. No real user Trash has been deleted during development. Full-window interaction, keyboard, VoiceOver, live permission prompts and actual user-Mac acceptance remain manual checks; use only a disposable owned fixture account for destructive acceptance.
